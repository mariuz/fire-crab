//! fcevt - replay an event scenario through the converted table.
//!
//!   fcevt replay
//!
//! Runs the scenario the paper's event clients demonstrate - subscribe,
//! post-and-rollback, three-posts-then-commit - and prints one line per
//! observable step, in the same vocabulary the sample prints, for the
//! gate to compare against the live engine's behaviour.

use fire_crab_evt::EventTable;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(|s| s.as_str()) != Some("replay") {
        eprintln!("usage: fcevt replay");
        std::process::exit(2);
    }
    let mut t = EventTable::new();
    let s = t.create_session();
    // SUBSCRIBE THE WAY EVERY DRIVER DOES: register, take the delivery
    // that fires at once as the baseline, and register again at it.
    // Registration always fires on a fresh event (the engine's test is
    // `rint_count <= evnt_count`) and carries `evnt_count + 1`, so the
    // baseline a client holds is 1 and not 0.
    let first = t.queue(s, "FC_EVT", 0);
    let baseline = first.first().map(|d| d.count).unwrap_or(0);
    if baseline != 0 {
        t.queue(s, "FC_EVT", baseline);
    }
    println!("subscribed baseline={} immediate={}", baseline, first.len());

    // post then ROLLBACK: nobody hears it
    t.post(1, "FC_EVT");
    t.rollback(1);
    println!("after rollback deliveries=0 counter={}", t.count("FC_EVT"));

    // three posts, still uncommitted
    t.post(2, "FC_EVT");
    t.post(2, "FC_EVT");
    t.post(2, "FC_EVT");
    println!("before commit deliveries=0 counter={}", t.count("FC_EVT"));

    // COMMIT: one delivery carrying the new counter
    let d = t.commit(2);
    for x in &d {
        println!(
            "after commit deliveries={} name={} counter={} delta={}",
            d.len(),
            x.name,
            x.count,
            x.count - baseline
        );
    }
}
