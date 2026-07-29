//! The event manager - the conversion of `src/jrd/event.cpp`'s
//! counter-and-interest model together with the transaction coupling
//! that decides WHEN a post becomes a delivery.
//!
//! # What an event actually is
//!
//! Not a message: a COUNTER. The engine's event block (`evnt`,
//! event.h:105) holds a name and `evnt_count`; a client's request
//! registers an INTEREST (`req_int`) carrying a THRESHOLD count
//! (`rint_count`), and the interest fires when the event's counter
//! passes it. Everything the surface does follows from that:
//!
//! - **Delivery is COMMIT-TIME.** `POST_EVENT` inside a transaction
//!   changes nothing visible; the counter moves when the transaction
//!   commits.
//! - **Rollback swallows posts.** They were never counted.
//! - **Posts COALESCE.** Three posts of one name in one transaction
//!   move the counter by three and produce ONE delivery carrying the
//!   new count - a client learns "it happened, and the counter is
//!   now N", never "here are three messages".
//! - **A fresh interest below the current count fires at once**,
//!   which is why a subscribing client immediately receives the
//!   current counter as its baseline.
//!
//! # The oracle
//!
//! The paper ships working event clients in four languages; the node
//! one prints exactly these laws (`samples/nodejs/events.js`), so the
//! gate runs it against the LIVE engine and then replays the same
//! scenario through this crate, asserting the same deliveries and the
//! same counter deltas. That is a SEMANTIC differential rather than a
//! byte one: the shared-memory arena is transport, but who gets told
//! what, and when, is policy - and policy is what can be wrong.
//!
//! # Slice 1 boundaries
//!
//! The shared-memory arena (self-relative queues, process and session
//! blocks, the watcher thread) and the wire delivery path (the
//! auxiliary connection carrying op_event) are transport and stay
//! unconverted. Cross-process posting, event cancellation timing and
//! the AST callback are named refusals in the roadmap.

use std::collections::BTreeMap;

/// A registered interest: the session that wants the event and the
/// counter value it has already seen (`rint_count`). It fires when
/// the event's counter passes that threshold.
#[derive(Clone, Debug, PartialEq)]
pub struct Interest {
    pub session: u32,
    pub name: String,
    pub threshold: i64,
}

/// One delivery: the event name and the counter value AT DELIVERY -
/// what `op_event` carries and what a client reads as its new
/// baseline.
#[derive(Clone, Debug, PartialEq)]
pub struct Delivery {
    pub session: u32,
    pub name: String,
    pub count: i64,
}

/// The event table: counters by name, the live interests, and the
/// per-transaction post buffers.
#[derive(Default)]
pub struct EventTable {
    counts: BTreeMap<String, i64>,
    interests: Vec<Interest>,
    /// posts buffered per transaction: name -> how many times
    pending: BTreeMap<u64, BTreeMap<String, i64>>,
    next_session: u32,
}

impl EventTable {
    pub fn new() -> EventTable {
        EventTable::default()
    }

    /// A client session (an attachment's event request).
    pub fn create_session(&mut self) -> u32 {
        self.next_session += 1;
        self.next_session
    }

    /// The current counter for a name - zero for a name never posted
    /// (the engine makes the event block on demand, counter 0).
    pub fn count(&self, name: &str) -> i64 {
        *self.counts.get(name).unwrap_or(&0)
    }

    /// `op_que_events`: register an interest at the count the client
    /// believes it has seen. An interest already BELOW the current
    /// counter fires immediately - the engine has news for it - which
    /// is how a subscriber learns the current value as its baseline.
    pub fn queue(&mut self, session: u32, name: &str, seen: i64) -> Vec<Delivery> {
        let now = self.count(name);
        if now > seen {
            return vec![Delivery {
                session,
                name: name.to_string(),
                count: now,
            }];
        }
        self.interests.push(Interest {
            session,
            name: name.to_string(),
            threshold: seen,
        });
        Vec::new()
    }

    /// `op_cancel_events`: drop every interest of a session.
    pub fn cancel(&mut self, session: u32) {
        self.interests.retain(|i| i.session != session);
    }

    /// `POST_EVENT` inside transaction `tx` - buffered, not counted.
    /// Nothing is delivered here, however many times it is called.
    pub fn post(&mut self, tx: u64, name: &str) {
        *self
            .pending
            .entry(tx)
            .or_default()
            .entry(name.to_string())
            .or_insert(0) += 1;
    }

    /// COMMIT: every buffered post lands on its counter, and each
    /// interest the new counter has passed fires ONCE - carrying the
    /// counter, not the number of posts. The fired interest comes
    /// down (the client re-queues to hear again, exactly as the
    /// drivers do).
    pub fn commit(&mut self, tx: u64) -> Vec<Delivery> {
        let Some(posts) = self.pending.remove(&tx) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for (name, times) in posts {
            let c = self.counts.entry(name.clone()).or_insert(0);
            *c += times;
            let now = *c;
            let mut kept = Vec::new();
            for i in std::mem::take(&mut self.interests) {
                if i.name == name && now > i.threshold {
                    out.push(Delivery {
                        session: i.session,
                        name: name.clone(),
                        count: now,
                    });
                } else {
                    kept.push(i);
                }
            }
            self.interests = kept;
        }
        out
    }

    /// ROLLBACK: the posts were never counted, so nobody hears them.
    pub fn rollback(&mut self, tx: u64) {
        self.pending.remove(&tx);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn delivery_is_commit_time() {
        let mut t = EventTable::new();
        let s = t.create_session();
        assert!(t.queue(s, "E", 0).is_empty());
        t.post(1, "E");
        // nothing yet - the counter has not moved
        assert_eq!(t.count("E"), 0);
        let d = t.commit(1);
        assert_eq!(
            d,
            vec![Delivery { session: s, name: "E".into(), count: 1 }]
        );
        assert_eq!(t.count("E"), 1);
    }

    #[test]
    fn rollback_swallows_posts() {
        let mut t = EventTable::new();
        let s = t.create_session();
        t.queue(s, "E", 0);
        t.post(1, "E");
        t.post(1, "E");
        t.rollback(1);
        assert_eq!(t.count("E"), 0);
        // and a later commit of a DIFFERENT transaction still works
        t.post(2, "E");
        assert_eq!(t.commit(2).len(), 1);
    }

    #[test]
    fn posts_coalesce_into_one_delivery_carrying_the_count() {
        let mut t = EventTable::new();
        let s = t.create_session();
        t.queue(s, "E", 0);
        t.post(1, "E");
        t.post(1, "E");
        t.post(1, "E");
        let d = t.commit(1);
        // ONE delivery, counter moved by THREE
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].count, 3);
        assert_eq!(t.count("E"), 3);
    }

    #[test]
    fn a_late_subscriber_gets_the_current_count_at_once() {
        let mut t = EventTable::new();
        let early = t.create_session();
        t.queue(early, "E", 0);
        t.post(1, "E");
        t.commit(1);
        // a session that has seen nothing subscribes AFTER the post:
        // the engine has news, so it fires immediately
        let late = t.create_session();
        let d = t.queue(late, "E", 0);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].count, 1);
        // ...but one that already knows the count waits
        let caught_up = t.create_session();
        assert!(t.queue(caught_up, "E", 1).is_empty());
    }

    #[test]
    fn a_fired_interest_comes_down_until_requeued() {
        let mut t = EventTable::new();
        let s = t.create_session();
        t.queue(s, "E", 0);
        t.post(1, "E");
        assert_eq!(t.commit(1).len(), 1);
        // the interest fired and is gone: a second commit tells
        // nobody until the client re-queues
        t.post(2, "E");
        assert!(t.commit(2).is_empty());
        t.queue(s, "E", 2);
        t.post(3, "E");
        assert_eq!(t.commit(3)[0].count, 3);
    }

    #[test]
    fn unrelated_names_and_cancellation() {
        let mut t = EventTable::new();
        let s = t.create_session();
        t.queue(s, "E", 0);
        t.post(1, "OTHER");
        assert!(t.commit(1).is_empty());
        t.cancel(s);
        t.post(2, "E");
        assert!(t.commit(2).is_empty());
    }
}
