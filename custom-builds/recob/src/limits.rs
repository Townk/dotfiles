//! Pre-authentication limits (§3.5) and per-operation rate limits (§9.5).
//!
//! A long-lived daemon changes the blast radius of a flood. Where each
//! connection used to be an independent `socat` child with the operating
//! system's own limits as the backstop, one process now owns the accept loop for
//! every client, so a peer that opens connections and then stalls can starve
//! every legitimate user. Authorization does not help: it is evaluated per
//! operation, long after the descriptor is spent.
//!
//! Everything here is an in-memory counter behind a mutex, and exact. Revision 1
//! of the spec had to specify approximate counters in a state file with a bounded
//! `flock`, because forked handlers cannot update parent state; that apparatus,
//! and its lost-increment and corrupt-file failure modes, exists only in a design
//! with a process per connection.
//!
//! **Per endpoint, and that is an inference this file is explicit about.** §9.5
//! states it for the rate buckets, with the reasoning that a flood arriving over
//! the tunnel must not throttle the human's own local operations — "rate limiting
//! that becomes a denial-of-service lever is worse than none." §3.5's table does
//! not say either way for the accept-time caps, but the identical argument
//! applies to them: a global 32-connection cap would let a public flood lock the
//! trusted socket out. They are keyed per endpoint for that reason.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::listen::Endpoint;
use crate::registry::Bucket;

/// §3.5 and §9.5 defaults. Held as a struct so a test can shrink a window
/// without waiting ten seconds for it.
#[derive(Clone, Copy, Debug)]
pub struct Caps {
    /// Concurrent live connections, per endpoint.
    pub live: usize,
    /// Unauthenticated connections in flight, per endpoint.
    pub unauthenticated: usize,
    /// New connections per `window`, per endpoint.
    pub new_connections: usize,
    pub window: Duration,
    /// §3.5: total bytes read before authentication.
    pub pre_auth_bytes: usize,
    /// §3.5: declared frame length, pre-auth. Far smaller than §4.2's 64 MiB —
    /// an unauthenticated peer must never be able to make the listener allocate a
    /// large buffer by asserting a large length.
    pub pre_auth_frame: usize,
    /// §3.5: the deadline for the preamble and hello together.
    pub handshake: Duration,
}

impl Default for Caps {
    fn default() -> Self {
        Caps {
            live: 32,
            unauthenticated: 8,
            new_connections: 30,
            window: Duration::from_secs(10),
            pre_auth_bytes: 8 * 1024,
            pre_auth_frame: 4 * 1024,
            handshake: Duration::from_secs(1),
        }
    }
}

/// §9.5's buckets: `osd` 20 per 10 s, `window` 5 per 10 s, `store` 120 per 10 s.
fn bucket_limit(bucket: Bucket) -> usize {
    match bucket {
        Bucket::Osd => 20,
        Bucket::Window => 5,
        Bucket::Store => 120,
    }
}

/// Why a connection was refused at accept (§3.5). All three answer `busy`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Refusal {
    Live,
    Unauthenticated,
    Rate,
}

impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::Live => "concurrent connection cap",
            Refusal::Unauthenticated => "unauthenticated in-flight cap",
            Refusal::Rate => "new-connection rate",
        }
    }
}

#[derive(Debug, Default)]
struct EndpointState {
    live: usize,
    unauthenticated: usize,
    /// Accept times inside the current window, oldest first.
    accepts: Vec<Instant>,
    buckets: HashMap<Bucket, Vec<Instant>>,
}

#[derive(Debug)]
pub struct Limits {
    caps: Caps,
    public: Mutex<EndpointState>,
    trusted: Mutex<EndpointState>,
}

impl Default for Limits {
    fn default() -> Self {
        Limits::with_caps(Caps::default())
    }
}

impl Limits {
    pub fn with_caps(caps: Caps) -> Self {
        Limits {
            caps,
            public: Mutex::new(EndpointState::default()),
            trusted: Mutex::new(EndpointState::default()),
        }
    }

    pub fn caps(&self) -> Caps {
        self.caps
    }

    fn state(&self, endpoint: Endpoint) -> &Mutex<EndpointState> {
        match endpoint {
            Endpoint::Public => &self.public,
            Endpoint::Trusted => &self.trusted,
        }
    }

    /// Admits a connection, or refuses it. On admission the caller holds an
    /// `Admission` whose drop releases both slots, so they are returned on every
    /// exit path including a panic — the guarantee the earlier draft needed a
    /// cross-process marker and `CHLD` handling to approximate.
    pub fn admit(self: &Arc<Self>, endpoint: Endpoint) -> Result<Admission, Refusal> {
        let now = Instant::now();
        let mut state = lock(self.state(endpoint));
        state
            .accepts
            .retain(|t| now.duration_since(*t) < self.caps.window);
        if state.live >= self.caps.live {
            return Err(Refusal::Live);
        }
        if state.unauthenticated >= self.caps.unauthenticated {
            return Err(Refusal::Unauthenticated);
        }
        if state.accepts.len() >= self.caps.new_connections {
            return Err(Refusal::Rate);
        }
        state.live += 1;
        state.unauthenticated += 1;
        state.accepts.push(now);
        drop(state);
        Ok(Admission {
            limits: Arc::clone(self),
            endpoint,
            unauthenticated: true,
        })
    }

    /// Seconds a refused peer should wait. For the rate window it is the time
    /// until the oldest accept ages out; for the capacity caps there is nothing
    /// to compute, and a second is short enough to retry against and long enough
    /// not to be a spin.
    pub fn retry_after(&self, endpoint: Endpoint, refusal: Refusal) -> u64 {
        if refusal != Refusal::Rate {
            return 1;
        }
        let state = lock(self.state(endpoint));
        let now = Instant::now();
        state
            .accepts
            .first()
            .map(|oldest| {
                let elapsed = now.duration_since(*oldest);
                self.caps
                    .window
                    .checked_sub(elapsed)
                    .map(|left| left.as_secs() + 1)
                    .unwrap_or(1)
            })
            .unwrap_or(1)
    }

    /// §9.5: exact, in memory, per endpoint. `Some(retry_after)` means the bucket
    /// is exhausted; a permitted call consumes one slot.
    pub fn rate_check(&self, endpoint: Endpoint, bucket: Bucket) -> Option<u64> {
        let now = Instant::now();
        let mut state = lock(self.state(endpoint));
        let window = self.caps.window;
        let hits = state.buckets.entry(bucket).or_default();
        hits.retain(|t| now.duration_since(*t) < window);
        if hits.len() >= bucket_limit(bucket) {
            let oldest = hits[0];
            let left = window
                .checked_sub(now.duration_since(oldest))
                .unwrap_or_default();
            return Some(left.as_secs() + 1);
        }
        hits.push(now);
        None
    }

    fn release(&self, endpoint: Endpoint, unauthenticated: bool) {
        let mut state = lock(self.state(endpoint));
        state.live = state.live.saturating_sub(1);
        if unauthenticated {
            state.unauthenticated = state.unauthenticated.saturating_sub(1);
        }
    }

    fn authenticated(&self, endpoint: Endpoint) {
        let mut state = lock(self.state(endpoint));
        state.unauthenticated = state.unauthenticated.saturating_sub(1);
    }

    #[cfg(test)]
    fn counts(&self, endpoint: Endpoint) -> (usize, usize) {
        let state = lock(self.state(endpoint));
        (state.live, state.unauthenticated)
    }
}

/// A mutex guarding counters is never held across a fallible operation, so
/// poisoning can only mean a panic elsewhere left the counts as they were.
/// Refusing to serve on that basis would turn one handler panic into an outage.
fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Holds a connection's slots. §3.5: a connection occupies an *unauthenticated
/// in-flight* slot from accept until it either authenticates or closes —
/// releasing it at dispatch would make the counter meaningless, since the whole
/// point is to bound peers that connect and then stall.
#[derive(Debug)]
pub struct Admission {
    limits: Arc<Limits>,
    endpoint: Endpoint,
    unauthenticated: bool,
}

impl Admission {
    pub fn authenticated(&mut self) {
        if self.unauthenticated {
            self.limits.authenticated(self.endpoint);
            self.unauthenticated = false;
        }
    }
}

impl Drop for Admission {
    fn drop(&mut self) {
        self.limits.release(self.endpoint, self.unauthenticated);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(caps: Caps) -> Arc<Limits> {
        Arc::new(Limits::with_caps(caps))
    }

    #[test]
    fn the_live_cap_admits_up_to_the_limit_and_releases_on_drop() {
        let caps = Caps {
            live: 2,
            unauthenticated: 99,
            new_connections: 99,
            ..Caps::default()
        };
        let l = limits(caps);
        let a = l.admit(Endpoint::Public).unwrap();
        let b = l.admit(Endpoint::Public).unwrap();
        assert_eq!(l.admit(Endpoint::Public).unwrap_err(), Refusal::Live);
        drop(a);
        let _c = l.admit(Endpoint::Public).unwrap();
        drop(b);
        assert_eq!(l.counts(Endpoint::Public).0, 1);
    }

    #[test]
    fn an_unauthenticated_slot_is_held_until_it_authenticates_or_closes() {
        let caps = Caps {
            live: 99,
            unauthenticated: 2,
            new_connections: 99,
            ..Caps::default()
        };
        let l = limits(caps);
        let mut stalling = l.admit(Endpoint::Public).unwrap();
        let _also_stalling = l.admit(Endpoint::Public).unwrap();
        assert_eq!(
            l.admit(Endpoint::Public).unwrap_err(),
            Refusal::Unauthenticated,
            "a peer that connects and says nothing occupies a slot"
        );
        stalling.authenticated();
        // The slot is freed by authenticating, while the connection stays live.
        let _third = l.admit(Endpoint::Public).unwrap();
        assert_eq!(l.counts(Endpoint::Public), (3, 2));
    }

    #[test]
    fn authenticating_twice_releases_one_slot_only() {
        let l = limits(Caps::default());
        let mut a = l.admit(Endpoint::Public).unwrap();
        a.authenticated();
        a.authenticated();
        assert_eq!(l.counts(Endpoint::Public), (1, 0));
        drop(a);
        assert_eq!(l.counts(Endpoint::Public), (0, 0));
    }

    #[test]
    fn the_new_connection_rate_is_counted_over_the_window() {
        let caps = Caps {
            live: 99,
            unauthenticated: 99,
            new_connections: 3,
            window: Duration::from_millis(120),
            ..Caps::default()
        };
        let l = limits(caps);
        // Drop each admission immediately: the rate cap counts accepts, not
        // occupancy, so closing does not buy a fresh slot.
        for _ in 0..3 {
            drop(l.admit(Endpoint::Public).unwrap());
        }
        assert_eq!(l.admit(Endpoint::Public).unwrap_err(), Refusal::Rate);
        assert!(l.retry_after(Endpoint::Public, Refusal::Rate) >= 1);
        std::thread::sleep(Duration::from_millis(150));
        assert!(l.admit(Endpoint::Public).is_ok(), "the window aged out");
    }

    #[test]
    fn accept_limits_are_per_endpoint() {
        // The §9.5 argument applied to §3.5: a public flood must not lock the
        // human out of the trusted socket.
        let caps = Caps {
            live: 1,
            unauthenticated: 1,
            new_connections: 1,
            ..Caps::default()
        };
        let l = limits(caps);
        let _public = l.admit(Endpoint::Public).unwrap();
        assert!(l.admit(Endpoint::Public).is_err());
        assert!(
            l.admit(Endpoint::Trusted).is_ok(),
            "the trusted endpoint has its own counters"
        );
    }

    #[test]
    fn a_rate_bucket_is_exact_and_reports_a_retry_after() {
        let l = limits(Caps {
            window: Duration::from_millis(150),
            ..Caps::default()
        });
        // §9.5: window is 5 per 10 s.
        for _ in 0..5 {
            assert_eq!(l.rate_check(Endpoint::Public, Bucket::Window), None);
        }
        let retry = l
            .rate_check(Endpoint::Public, Bucket::Window)
            .expect("the sixth call must be refused");
        assert!(retry >= 1);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(
            l.rate_check(Endpoint::Public, Bucket::Window),
            None,
            "the window aged out"
        );
    }

    #[test]
    fn buckets_do_not_bleed_into_each_other() {
        let l = limits(Caps::default());
        for _ in 0..5 {
            assert_eq!(l.rate_check(Endpoint::Public, Bucket::Window), None);
        }
        assert!(l.rate_check(Endpoint::Public, Bucket::Window).is_some());
        assert_eq!(
            l.rate_check(Endpoint::Public, Bucket::Osd),
            None,
            "osd has its own 20-per-window budget"
        );
    }

    #[test]
    fn exhausting_one_endpoints_bucket_does_not_throttle_the_other() {
        // §9.5's load-bearing half, and the Phase 2 done-criterion: a shared
        // bucket would let a peer across the tunnel throttle the human's own
        // local copies, turning a throttle into the denial-of-service lever it
        // exists to prevent.
        let l = limits(Caps::default());
        for _ in 0..5 {
            assert_eq!(l.rate_check(Endpoint::Public, Bucket::Window), None);
        }
        assert!(
            l.rate_check(Endpoint::Public, Bucket::Window).is_some(),
            "public is exhausted"
        );
        for _ in 0..5 {
            assert_eq!(
                l.rate_check(Endpoint::Trusted, Bucket::Window),
                None,
                "the trusted socket keeps its own full budget"
            );
        }
    }
}
