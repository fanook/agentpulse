# AgentPulse HTTP API

AgentPulse listens on `127.0.0.1` for events from agent hooks. The exact
port is written to `~/.pulse/port` on every launch (default `9876`,
falls through to `9877-9895` if busy).

All non-health endpoints require a bearer-style header:

```
X-AgentPulse-Token: <content of ~/.pulse/token>
```

The token is a 48-character hex string, written mode `0600` on first
launch. `~/.pulse/` itself is `0700`.

## `POST /hook`

Accepts a JSON envelope describing an agent lifecycle event.
Returns `204 No Content` on success, `401` on token mismatch,
`400` on malformed JSON, `404` on wrong path/method.

### Envelope

```jsonc
{
  "event":       "SessionStart",           // required; see events below
  "session_id":  "19ea01b5-...",           // required; agent's own session id
  "agent":       "claude",                 // optional; short lowercase identifier
  "cwd":         "/Users/you/my-project",  // optional; agent's working dir
  "transcript_path": "/path/to/log.jsonl", // optional; for custom-title scanning
  "notification_type": "permission_prompt",// only for event=Notification
  "exit_reason": "logout",                 // only for event=SessionEnd
  "tool_name":   "Edit",                   // only for event=PreToolUse|PostToolUse
  "tool_summary": "README.md",             // optional short label (filename, command, ...)
  "terminal": {
    "termProgram": "iTerm.app",
    "iTermSessionId": "w0t0p0:UUID",
    "tmuxPane": "%12",
    "tmuxSocket": "/private/tmp/tmux-501/default",
    "wezTermPane": "<id>",
    "terminalEmulator": "JetBrains-JediTerm",
    "ppid": 12345,
    "tty":  "ttys026"
  }
}
```

All fields except `event` and `session_id` are optional. Unknown keys
are ignored. Agents should send only what they can cheaply collect.

### Events

| `event`            | effect                                                          |
| ------------------ | --------------------------------------------------------------- |
| `SessionStart`     | create/refresh session; status = `running`                      |
| `UserPromptSubmit` | status = `thinking`                                             |
| `PreToolUse`       | status = `running`; activity = `"<tool_name> <tool_summary>"`   |
| `PostToolUse`      | clear activity; status = `thinking` (will flip to idle on Stop) |
| `Notification`     | if `notification_type = permission_prompt` → `waiting` + banner |
| `Stop`             | status = `idle`; clear activity                                 |
| `CwdChanged`       | refresh cwd (no status change)                                  |
| `SessionEnd`       | remove the session from the list                                |

Unknown events are silently dropped — safe for forward compatibility.

### Terminal hints

The `terminal` object is a grab-bag of identifiers AgentPulse uses to
bring the right window to front when the user clicks a row. Agents can
populate whichever subset applies. See `Sources/AgentPulse/Jumper.swift`
for how each field is used.

### Example — minimal ping

```bash
curl -sS -X POST \
  -H 'Content-Type: application/json' \
  -H "X-AgentPulse-Token: $(cat ~/.pulse/token)" \
  --data '{
    "event": "SessionStart",
    "session_id": "demo-1",
    "agent": "shell",
    "cwd": "/tmp/demo"
  }' \
  "http://127.0.0.1:$(cat ~/.pulse/port)/hook"
```

## `GET /health`

Returns `200 ok`. Does **not** require the token — useful for probing
whether AgentPulse is running.

```bash
curl -sS "http://127.0.0.1:$(cat ~/.pulse/port)/health"
# => ok
```

## Client-side guidance

Hooks run in the agent's process, sometimes synchronously blocking it.
Keep the outbound request fire-and-forget:

- `--max-time 1`
- swallow errors (`|| true`)
- exit `0`

If AgentPulse isn't running, the port file may be stale or missing —
your hook must tolerate that without breaking the agent.
