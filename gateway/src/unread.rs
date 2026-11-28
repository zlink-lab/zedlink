//! Unread counters (`summary.unread`, `summary.mark_read`, APNs `badge`).
//!
//! Every agent event the notification monitor detects (done, stopped, error, approval, input)
//! increments a per-thread counter, whether or not a push was sent. Each device keeps the
//! counter value it has seen per thread.

use super::*;
use std::collections::BTreeMap;

const MAX_THREADS: usize = 1024;

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub(super) struct ThreadEvents {
    pub(super) count: u64,
    /// Unix seconds of the last event; the oldest threads are forgotten first.
    pub(super) at: i64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub(super) struct UnreadState {
    /// `target:thread` → events.
    #[serde(default)]
    pub(super) events: BTreeMap<String, ThreadEvents>,
    /// device id → `target:thread` → events seen.
    #[serde(default)]
    pub(super) read: BTreeMap<String, BTreeMap<String, u64>>,
}

impl UnreadState {
    pub(super) fn record_event(&mut self, key: &str, now: i64) {
        let entry = self.events.entry(key.to_owned()).or_default();
        entry.count += 1;
        entry.at = now;
        while self.events.len() > MAX_THREADS {
            let Some(oldest) = self
                .events
                .iter()
                .min_by_key(|(_, events)| events.at)
                .map(|(key, _)| key.clone())
            else {
                break;
            };
            self.events.remove(&oldest);
            for marks in self.read.values_mut() {
                marks.remove(&oldest);
            }
        }
    }

    pub(super) fn mark_read(&mut self, device: Uuid, key: &str) {
        let count = self.events.get(key).map_or(0, |events| events.count);
        let marks = self.read.entry(device.to_string()).or_default();
        if count == 0 {
            marks.remove(key);
        } else {
            marks.insert(key.to_owned(), count);
        }
    }

    /// A message typed in desktop Zed: the user has seen the thread.
    pub(super) fn mark_read_everywhere<'a>(
        &mut self,
        key: &str,
        devices: impl IntoIterator<Item = &'a Uuid>,
    ) {
        for device in devices {
            self.mark_read(*device, key);
        }
    }

    /// A newly paired device starts with nothing unread.
    pub(super) fn start_device(&mut self, device: Uuid) {
        let marks = self
            .events
            .iter()
            .map(|(key, events)| (key.clone(), events.count))
            .collect();
        self.read.insert(device.to_string(), marks);
    }

    pub(super) fn forget_device(&mut self, device: Uuid) {
        self.read.remove(&device.to_string());
    }

    /// Per thread unread count (> 0 only) for a device, sorted by key.
    pub(super) fn unread(&self, device: Uuid) -> Vec<(String, u64)> {
        let marks = self.read.get(&device.to_string());
        self.events
            .iter()
            .filter_map(|(key, events)| {
                let seen = marks.and_then(|marks| marks.get(key)).copied().unwrap_or(0);
                let unread = events.count.saturating_sub(seen);
                (unread > 0).then(|| (key.clone(), unread))
            })
            .collect()
    }

    pub(super) fn total(&self, device: Uuid) -> u64 {
        self.unread(device).iter().map(|(_, unread)| unread).sum()
    }

    pub(super) fn summary(&self, device: Uuid) -> Value {
        let threads = self.unread(device);
        let total = threads.iter().map(|(_, unread)| unread).sum::<u64>();
        let threads = threads
            .into_iter()
            .filter_map(|(key, unread)| {
                let (target_id, thread_id) = key.split_once(':')?;
                Some(json!({"target_id": target_id, "thread_id": thread_id, "unread": unread}))
            })
            .collect::<Vec<_>>();
        json!({"total": total, "threads": threads})
    }
}

impl Gateway {
    pub(super) async fn record_thread_event(&self, target_id: &str, thread_id: &str) {
        let key = remote_thread_key(target_id, thread_id);
        self.mutate_persisted(|state| state.unread.record_event(&key, now_seconds()))
            .await;
    }

    pub(super) async fn mark_thread_read_everywhere(&self, target_id: &str, thread_id: &str) {
        let key = remote_thread_key(target_id, thread_id);
        let persisted = self.0.persisted.lock().await;
        let changed = persisted.devices.iter().any(|device| {
            let seen = persisted
                .unread
                .read
                .get(&device.id.to_string())
                .and_then(|marks| marks.get(&key))
                .copied()
                .unwrap_or(0);
            persisted.unread.events.get(&key).map_or(0, |e| e.count) != seen
        });
        drop(persisted);
        if changed {
            self.mutate_persisted(|state| {
                let devices = state
                    .devices
                    .iter()
                    .map(|device| device.id)
                    .collect::<Vec<_>>();
                state.unread.mark_read_everywhere(&key, &devices);
            })
            .await;
        }
    }

    /// `summary.unread` and `summary.mark_read`.
    pub(super) async fn summary_rpc(
        &self,
        method: &str,
        device: Uuid,
        target_id: Option<&str>,
        params: &Value,
    ) -> (StatusCode, Result<Value, Value>) {
        match method {
            "summary.unread" => (
                StatusCode::OK,
                Ok(self.0.persisted.lock().await.unread.summary(device)),
            ),
            "summary.mark_read" => {
                let target_id = params["target_id"].as_str().or(target_id);
                let Ok(target) = self.target(target_id) else {
                    return (
                        StatusCode::NOT_FOUND,
                        Err(json!({"code": "UNKNOWN_TARGET"})),
                    );
                };
                let Some(thread_id) = valid_thread_id(&params["thread_id"]) else {
                    return (
                        StatusCode::BAD_REQUEST,
                        Err(json!({"code": "INVALID_REQUEST"})),
                    );
                };
                let key = remote_thread_key(&target.id, thread_id);
                let total = self
                    .mutate_persisted(|state| {
                        state.unread.mark_read(device, &key);
                        state.unread.total(device)
                    })
                    .await;
                (StatusCode::OK, Ok(json!({"total": total})))
            }
            _ => (
                StatusCode::FORBIDDEN,
                Err(json!({"code": "UNSUPPORTED_CAPABILITY"})),
            ),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_unread_per_device_and_thread() {
        let phone = Uuid::new_v4();
        let tablet = Uuid::new_v4();
        let mut state = UnreadState::default();
        state.record_event("desktop:t1", 1);
        state.record_event("desktop:t1", 2);
        state.record_event("desktop:t2", 3);
        assert_eq!(state.total(phone), 3);
        state.mark_read(phone, "desktop:t1");
        assert_eq!(state.total(phone), 1);
        assert_eq!(state.total(tablet), 3);
        let summary = state.summary(phone);
        assert_eq!(summary["total"], 1);
        assert_eq!(
            summary["threads"],
            json!([{"target_id": "desktop", "thread_id": "t2", "unread": 1}])
        );
        // New events after a read mark count again.
        state.record_event("desktop:t1", 4);
        assert_eq!(state.total(phone), 2);
        // Typing in desktop Zed reads the thread for every device.
        state.mark_read_everywhere("desktop:t1", &[phone, tablet]);
        assert_eq!(state.total(phone), 1);
        assert_eq!(state.total(tablet), 1);
        // A new device starts at zero; a revoked one is forgotten.
        let fresh = Uuid::new_v4();
        state.start_device(fresh);
        assert_eq!(state.total(fresh), 0);
        state.forget_device(tablet);
        assert!(!state.read.contains_key(&tablet.to_string()));
        assert_eq!(state.total(tablet), 4);
    }

    #[test]
    fn forgets_the_oldest_threads_first() {
        let device = Uuid::new_v4();
        let mut state = UnreadState::default();
        for index in 0..(MAX_THREADS + 2) {
            state.record_event(&format!("d:{index}"), index as i64);
        }
        assert_eq!(state.events.len(), MAX_THREADS);
        assert!(!state.events.contains_key("d:0"));
        assert!(!state.events.contains_key("d:1"));
        assert!(state.events.contains_key("d:2"));
        assert_eq!(state.total(device), MAX_THREADS as u64);
    }
}
