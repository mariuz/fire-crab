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

/// WHAT A DELIVERY CARRIES IS THE COUNTER PLUS ONE.
///
/// `const SLONG count = event->evnt_count + 1;` (event.cpp:884) - the
/// engine adds it when it builds the buffer `op_event` ships, so a
/// client subscribing to an event nobody has ever posted reads 1, not
/// 0. The whole surface is written in those numbers: the paper's own
/// client prints `baseline counter = 1` and then `counter=4` after
/// three posts, and a converted table that shipped the raw counter
/// would print 0 and 3 - agreeing on the DELTA, which is what hid it,
/// and disagreeing on every absolute number a client sees.
const DELIVERED_OFFSET: i64 = 1;

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
    /// believes it has seen.
    ///
    /// THE REGISTRATION IS ALSO WHAT CREATES THE EVENT BLOCK
    /// (`EventManager::make_event`, event.cpp:1077, reached from the
    /// queue path). Before it there is no block, and [EventTable::post]
    /// has nothing to count - see there.
    ///
    /// An interest whose seen-count the counter has REACHED fires at
    /// once: the engine's test is `rint_count <= evnt_count`
    /// (event.cpp:303), so a fresh interest at 0 over a counter at 0
    /// fires immediately. That is why a subscriber always gets one
    /// delivery straight away, and why its baseline is 1 rather than 0
    /// ([DELIVERED_OFFSET]).
    pub fn queue(&mut self, session: u32, name: &str, seen: i64) -> Vec<Delivery> {
        let now = *self.counts.entry(name.to_string()).or_insert(0);
        if seen <= now {
            return vec![Delivery {
                session,
                name: name.to_string(),
                count: now + DELIVERED_OFFSET,
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
    ///
    /// Whether the post counts AT ALL is decided at commit, not here:
    /// see [EventTable::commit].
    pub fn post(&mut self, tx: u64, name: &str) {
        *self
            .pending
            .entry(tx)
            .or_default()
            .entry(name.to_string())
            .or_insert(0) += 1;
    }

    /// COMMIT: every buffered post lands on its counter, and each
    /// interest the new counter has REACHED fires ONCE - carrying the
    /// counter, not the number of posts. The fired interest comes
    /// down (the client re-queues to hear again, exactly as the
    /// drivers do).
    ///
    /// **A POST TO A NAME NOBODY HAS EVER LISTENED FOR IS DROPPED.**
    /// `EventManager::postEvent` looks the name up and does nothing at
    /// all when there is no event block (`if (event)`, event.cpp:376) -
    /// no block, no counter, no history. Measured live: two posts
    /// before any client subscribed left the next subscriber's baseline
    /// at 1, not 3. It is decided HERE rather than in
    /// [EventTable::post] because the engine posts at commit, so a
    /// listener that subscribed while the transaction was open still
    /// counts.
    pub fn commit(&mut self, tx: u64) -> Vec<Delivery> {
        let Some(posts) = self.pending.remove(&tx) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for (name, times) in posts {
            let Some(c) = self.counts.get_mut(&name) else {
                continue; // no event block: the post is dropped whole
            };
            *c += times;
            let now = *c;
            let mut kept = Vec::new();
            for i in std::mem::take(&mut self.interests) {
                // the engine's own test, `rint_count <= evnt_count`
                // (event.cpp:388)
                if i.name == name && i.threshold <= now {
                    out.push(Delivery {
                        session: i.session,
                        name: name.clone(),
                        count: now + DELIVERED_OFFSET,
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

    /// Subscribe the way every driver does: register, and if that fires
    /// at once, register again at the count it delivered. Returns the
    /// baseline the client would hold.
    fn subscribe(t: &mut EventTable, s: u32, name: &str) -> i64 {
        let first = t.queue(s, name, 0);
        match first.first() {
            Some(d) => {
                let baseline = d.count;
                assert!(t.queue(s, name, baseline).is_empty());
                baseline
            }
            None => 0,
        }
    }

    /// A FRESH SUBSCRIPTION FIRES IMMEDIATELY AND CARRIES 1. The
    /// engine's test is `rint_count <= evnt_count` and its buffer holds
    /// `evnt_count + 1`, so 0 over 0 fires and delivers 1 - which is
    /// what the paper's client prints as `baseline counter = 1`.
    #[test]
    fn a_fresh_subscription_fires_at_once_carrying_one() {
        let mut t = EventTable::new();
        let s = t.create_session();
        let d = t.queue(s, "E", 0);
        assert_eq!(d, vec![Delivery { session: s, name: "E".into(), count: 1 }]);
        // the counter itself has not moved - the block merely exists now
        assert_eq!(t.count("E"), 0);
    }

    #[test]
    fn delivery_is_commit_time() {
        let mut t = EventTable::new();
        let s = t.create_session();
        assert_eq!(subscribe(&mut t, s, "E"), 1);
        t.post(1, "E");
        // nothing yet - the counter has not moved
        assert_eq!(t.count("E"), 0);
        let d = t.commit(1);
        assert_eq!(
            d,
            vec![Delivery { session: s, name: "E".into(), count: 2 }]
        );
        assert_eq!(t.count("E"), 1);
    }

    #[test]
    fn rollback_swallows_posts() {
        let mut t = EventTable::new();
        let s = t.create_session();
        subscribe(&mut t, s, "E");
        t.post(1, "E");
        t.post(1, "E");
        t.rollback(1);
        assert_eq!(t.count("E"), 0);
        // and a later commit of a DIFFERENT transaction still works
        t.post(2, "E");
        assert_eq!(t.commit(2).len(), 1);
    }

    /// The paper's client prints exactly these numbers: a baseline of 1,
    /// then one delivery carrying 4 after three posts in one
    /// transaction.
    #[test]
    fn posts_coalesce_into_one_delivery_carrying_the_count() {
        let mut t = EventTable::new();
        let s = t.create_session();
        let baseline = subscribe(&mut t, s, "E");
        t.post(1, "E");
        t.post(1, "E");
        t.post(1, "E");
        let d = t.commit(1);
        // ONE delivery, counter moved by THREE
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].count, 4);
        assert_eq!(d[0].count - baseline, 3);
        assert_eq!(t.count("E"), 3);
    }

    #[test]
    fn a_late_subscriber_gets_the_current_count_at_once() {
        let mut t = EventTable::new();
        let early = t.create_session();
        subscribe(&mut t, early, "E");
        t.post(1, "E");
        t.commit(1);
        // a session that has seen nothing subscribes AFTER the post:
        // the engine has news, so it fires immediately, carrying the
        // counter plus one
        let late = t.create_session();
        let d = t.queue(late, "E", 0);
        assert_eq!(d.len(), 1);
        assert_eq!(d[0].count, 2);
        // ...and one that already knows the count waits
        let caught_up = t.create_session();
        assert!(t.queue(caught_up, "E", 2).is_empty());
    }

    #[test]
    fn a_fired_interest_comes_down_until_requeued() {
        let mut t = EventTable::new();
        let s = t.create_session();
        subscribe(&mut t, s, "E");
        t.post(1, "E");
        assert_eq!(t.commit(1).len(), 1);
        // the interest fired and is gone: a second commit tells
        // nobody until the client re-queues
        t.post(2, "E");
        assert!(t.commit(2).is_empty());
        t.queue(s, "E", 3);
        t.post(3, "E");
        assert_eq!(t.commit(3)[0].count, 4);
    }

    /// A POST NOBODY HAS EVER LISTENED FOR IS DROPPED - no block, no
    /// counter, no history (`if (event)`, event.cpp:376). Measured
    /// live: two posts before any subscriber left the next one's
    /// baseline at 1.
    #[test]
    fn a_post_nobody_listens_for_is_dropped() {
        let mut t = EventTable::new();
        t.post(1, "E");
        t.post(1, "E");
        assert!(t.commit(1).is_empty());
        assert_eq!(t.count("E"), 0);
        // ...and the subscriber that arrives afterwards is told 1, not 3
        let s = t.create_session();
        assert_eq!(t.queue(s, "E", 0)[0].count, 1);
        // once the block exists, posts count
        t.post(2, "E");
        t.commit(2);
        assert_eq!(t.count("E"), 1);
    }

    #[test]
    fn unrelated_names_and_cancellation() {
        let mut t = EventTable::new();
        let s = t.create_session();
        subscribe(&mut t, s, "E");
        t.post(1, "OTHER");
        assert!(t.commit(1).is_empty());
        t.cancel(s);
        t.post(2, "E");
        assert!(t.commit(2).is_empty());
    }
}
