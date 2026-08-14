//! Per-turn capture of streamed agent output and relay-send tool calls.
//!
//! The harness delivers the agent's reply to the channel only when the agent
//! itself sends a message through the relay (via the MCP shell tool running
//! `buzz messages send`). Models that stream their answer as plain
//! `agent_message_chunk` text and never call the tool produce silence. This
//! module records both signals per turn so the pool can publish the streamed
//! text as a fallback reply when a turn ends without a send
//! (see `deliver_final_message_fallback` in `pool.rs`).

use std::collections::HashMap;

/// Hard cap on accumulated transcript bytes per turn. Agents can emit a
/// gapless infinite chunk stream (see the hard-deadline regression test in
/// `acp.rs`), so accumulation must be bounded. 64 KiB matches the relay's
/// message content ceiling; text past the cap is dropped, not rotated.
const TURN_TRANSCRIPT_CAP: usize = 64 * 1024;

/// Accumulates one turn's streamed agent text and observed relay-send tool
/// calls. One instance per [`AcpClient`](crate::acp::AcpClient); there is
/// exactly one turn in flight per client, so no cross-turn synchronization is
/// needed. State is reset at the start of every prompt via [`begin_turn`].
///
/// [`begin_turn`]: TurnCapture::begin_turn
#[derive(Debug, Default)]
pub struct TurnCapture {
    transcript: String,
    truncated: bool,
    /// toolCallId → whether the call is known to have failed.
    send_tool_calls: HashMap<String, bool>,
    /// A send-shaped tool call arrived without a toolCallId; treat as sent.
    send_attempted_untracked: bool,
}

impl TurnCapture {
    /// Reset all per-turn state. Called at prompt dispatch, which also
    /// discards any setup-prompt prose captured outside a real turn.
    pub fn begin_turn(&mut self) {
        self.transcript.clear();
        self.truncated = false;
        self.send_tool_calls.clear();
        self.send_attempted_untracked = false;
    }

    /// Append one `agent_message_chunk` text fragment, bounded by
    /// [`TURN_TRANSCRIPT_CAP`].
    pub fn append_chunk(&mut self, text: &str) {
        if self.truncated {
            return;
        }
        let remaining = TURN_TRANSCRIPT_CAP.saturating_sub(self.transcript.len());
        if text.len() <= remaining {
            self.transcript.push_str(text);
        } else {
            let mut cut = remaining;
            while cut > 0 && !text.is_char_boundary(cut) {
                cut -= 1;
            }
            self.transcript.push_str(&text[..cut]);
            self.truncated = true;
        }
    }

    /// Record a `tool_call` update. Send-shaped calls are tracked by id so a
    /// later `tool_call_update` can mark them failed.
    pub fn note_tool_call(
        &mut self,
        title: &str,
        raw_input: Option<&serde_json::Value>,
        tool_call_id: Option<&str>,
    ) {
        let raw = raw_input.map(|v| v.to_string()).unwrap_or_default();
        if !looks_like_relay_send(title) && !looks_like_relay_send(&raw) {
            return;
        }
        match tool_call_id {
            Some(id) => {
                self.send_tool_calls.insert(id.to_string(), false);
            }
            None => self.send_attempted_untracked = true,
        }
    }

    /// Record a `tool_call_update`; only failed status transitions matter.
    pub fn note_tool_call_update(&mut self, tool_call_id: &str, status: &str) {
        if status == "failed" {
            if let Some(failed) = self.send_tool_calls.get_mut(tool_call_id) {
                *failed = true;
            }
        }
    }

    /// Whether the agent attempted a relay message send this turn that is not
    /// known to have failed. Conservative in the "sent" direction: an
    /// attempted send whose outcome was never reported counts as sent,
    /// because double-posting is worse than the silence being rescued.
    pub fn sent_relay_message(&self) -> bool {
        self.send_attempted_untracked || self.send_tool_calls.values().any(|failed| !failed)
    }

    /// Consume the turn transcript. Returns trimmed non-empty text at most
    /// once; subsequent calls return `None` until text accumulates again.
    pub fn take_transcript(&mut self) -> Option<String> {
        let text = std::mem::take(&mut self.transcript);
        self.truncated = false;
        let trimmed = text.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    }
}

/// Whether a tool-call title or serialized raw input describes a relay
/// message send: the tokens `buzz`, (`messages`|`dms`), and a `send`-prefixed
/// subcommand (`send`, `send-diff`, …) appearing consecutively. Token-based
/// so `buzz messages list` or an unrelated tool named "send" never match.
fn looks_like_relay_send(text: &str) -> bool {
    let tokens: Vec<&str> = text
        .split(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == '`')
        .filter(|t| !t.is_empty())
        .collect();
    tokens.windows(3).any(|w| {
        w[0].ends_with("buzz")
            && (w[1] == "messages" || w[1] == "dms")
            && (w[2] == "send" || w[2].starts_with("send-"))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accumulates_and_takes_once() {
        let mut c = TurnCapture::default();
        c.append_chunk("Hello ");
        c.append_chunk("world");
        assert_eq!(c.take_transcript().as_deref(), Some("Hello world"));
        assert_eq!(c.take_transcript(), None);
    }

    #[test]
    fn take_trims_and_rejects_whitespace_only() {
        let mut c = TurnCapture::default();
        c.append_chunk("  \n\t ");
        assert_eq!(c.take_transcript(), None);
        c.append_chunk("  answer \n");
        assert_eq!(c.take_transcript().as_deref(), Some("answer"));
    }

    #[test]
    fn begin_turn_resets_everything() {
        let mut c = TurnCapture::default();
        c.append_chunk("stale setup prose");
        c.note_tool_call("shell", None, Some("id1"));
        c.note_tool_call("buzz messages send --channel x", None, Some("id2"));
        assert!(c.sent_relay_message());
        c.begin_turn();
        assert!(!c.sent_relay_message());
        assert_eq!(c.take_transcript(), None);
    }

    #[test]
    fn cap_enforced_on_char_boundary() {
        let mut c = TurnCapture::default();
        // 3-byte chars; the cap must never split one.
        let chunk = "€".repeat(30_000); // 90_000 bytes > 64 KiB
        c.append_chunk(&chunk);
        let text = c.take_transcript().expect("capped text");
        assert!(text.len() <= TURN_TRANSCRIPT_CAP);
        assert!(text.chars().all(|ch| ch == '€'));
    }

    #[test]
    fn truncated_state_drops_later_chunks() {
        let mut c = TurnCapture::default();
        c.append_chunk(&"a".repeat(TURN_TRANSCRIPT_CAP));
        c.append_chunk("overflow");
        let text = c.take_transcript().expect("text");
        assert_eq!(text.len(), TURN_TRANSCRIPT_CAP);
        assert!(!text.contains("overflow"));
    }

    #[test]
    fn send_detection_truth_table() {
        // (title, raw_input, expected)
        let cases = [
            (
                "buzz-dev-mcp: shell · buzz messages send --channel abc",
                None,
                true,
            ),
            (
                "shell",
                Some(r#"{"command":"buzz messages send --channel abc -m hi"}"#),
                true,
            ),
            (
                "shell",
                Some(r#"{"command":"buzz dms send --to pk -m hi"}"#),
                true,
            ),
            (
                "shell",
                Some(r#"{"command":"buzz messages send-diff --channel abc"}"#),
                true,
            ),
            (
                "shell",
                Some(r#"{"command":"/usr/local/bin/buzz messages send -m hi"}"#),
                true,
            ),
            (
                "shell",
                Some(r#"{"command":"buzz messages list --channel abc"}"#),
                false,
            ),
            (
                "shell",
                Some(r#"{"command":"buzz feed get --limit 5"}"#),
                false,
            ),
            (
                "read_file",
                Some(r#"{"path":"notes/buzz messages send.md"}"#),
                false,
            ),
            (
                "shell",
                Some(r#"{"command":"echo buzz && messages send"}"#),
                false,
            ),
        ];
        for (title, raw, expected) in cases {
            let mut c = TurnCapture::default();
            let raw_val = raw.map(|r| serde_json::from_str::<serde_json::Value>(r).unwrap());
            c.note_tool_call(title, raw_val.as_ref(), Some("id"));
            assert_eq!(
                c.sent_relay_message(),
                expected,
                "title={title:?} raw={raw:?}"
            );
        }
    }

    #[test]
    fn failed_send_counts_as_not_sent() {
        let mut c = TurnCapture::default();
        c.note_tool_call("buzz messages send --channel x", None, Some("id1"));
        assert!(c.sent_relay_message());
        c.note_tool_call_update("id1", "failed");
        assert!(!c.sent_relay_message());
    }

    #[test]
    fn one_success_among_failures_counts_as_sent() {
        let mut c = TurnCapture::default();
        c.note_tool_call("buzz messages send --channel x", None, Some("id1"));
        c.note_tool_call("buzz messages send --channel x", None, Some("id2"));
        c.note_tool_call_update("id1", "failed");
        assert!(c.sent_relay_message());
    }

    #[test]
    fn untracked_send_counts_as_sent() {
        let mut c = TurnCapture::default();
        c.note_tool_call("buzz messages send --channel x", None, None);
        assert!(c.sent_relay_message());
    }

    #[test]
    fn completed_status_leaves_sent() {
        let mut c = TurnCapture::default();
        c.note_tool_call("buzz messages send --channel x", None, Some("id1"));
        c.note_tool_call_update("id1", "completed");
        assert!(c.sent_relay_message());
    }

    #[test]
    fn non_send_tools_ignored() {
        let mut c = TurnCapture::default();
        c.note_tool_call(
            "read_file",
            Some(&serde_json::json!({"path": "a.txt"})),
            Some("id1"),
        );
        c.note_tool_call_update("id1", "completed");
        assert!(!c.sent_relay_message());
    }
}
