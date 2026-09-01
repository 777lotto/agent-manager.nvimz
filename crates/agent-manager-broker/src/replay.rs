//! Bounded, monotonic public-event replay.

use std::collections::VecDeque;

use crate::protocol::EventEnvelope;

#[derive(Clone, Debug, PartialEq)]
pub enum ReplayResult {
    Events(Vec<EventEnvelope>),
    ResyncRequired { oldest: u64, latest: u64 },
}

#[derive(Debug)]
pub struct ReplayBuffer {
    capacity: usize,
    next_sequence: u64,
    events: VecDeque<EventEnvelope>,
}

impl ReplayBuffer {
    #[must_use]
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0, "replay capacity must be positive");
        Self {
            capacity,
            next_sequence: 1,
            events: VecDeque::with_capacity(capacity),
        }
    }

    pub fn push(&mut self, mut event: EventEnvelope) -> u64 {
        let sequence = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .expect("event sequence overflow");
        event.sequence = sequence;
        self.events.push_back(event);
        if self.events.len() > self.capacity {
            self.events.pop_front();
        }
        sequence
    }

    #[must_use]
    pub fn bounds(&self) -> Option<(u64, u64)> {
        Some((self.events.front()?.sequence, self.events.back()?.sequence))
    }

    #[must_use]
    pub fn replay_after(&self, after_sequence: u64) -> ReplayResult {
        let Some((oldest, latest)) = self.bounds() else {
            return ReplayResult::Events(Vec::new());
        };

        if after_sequence.saturating_add(1) < oldest {
            return ReplayResult::ResyncRequired { oldest, latest };
        }

        ReplayResult::Events(
            self.events
                .iter()
                .filter(|event| event.sequence > after_sequence)
                .cloned()
                .collect(),
        )
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{ReplayBuffer, ReplayResult};
    use crate::protocol::{EventEnvelope, Provider};

    fn event(kind: &str) -> EventEnvelope {
        EventEnvelope::new(
            "2026-08-31T18:00:00Z".to_owned(),
            "agent-1".to_owned(),
            Provider::Codex,
            kind.to_owned(),
            json!({}),
            json!({}),
        )
    }

    #[test]
    fn assigns_monotonic_sequences_and_replays_suffix() {
        let mut replay = ReplayBuffer::new(3);
        replay.push(event("turn.started"));
        replay.push(event("message.delta"));
        replay.push(event("turn.completed"));

        let ReplayResult::Events(events) = replay.replay_after(1) else {
            panic!("expected replay events");
        };
        assert_eq!(
            events
                .iter()
                .map(|event| event.sequence)
                .collect::<Vec<_>>(),
            [2, 3]
        );
    }

    #[test]
    fn requires_resync_when_cursor_falls_before_bounded_window() {
        let mut replay = ReplayBuffer::new(2);
        replay.push(event("turn.started"));
        replay.push(event("message.delta"));
        replay.push(event("turn.completed"));

        assert_eq!(
            replay.replay_after(0),
            ReplayResult::ResyncRequired {
                oldest: 2,
                latest: 3
            }
        );
    }
}
