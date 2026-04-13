# AgentPulse

> **macOS menu-bar companion for coding agents.**
> Stop staring at terminals waiting for permission prompts — AgentPulse
> watches every agent session you have running and pings you only when
> one actually needs you.

[![CI](https://github.com/fanook/agentpulse/actions/workflows/ci.yml/badge.svg)](https://github.com/fanook/agentpulse/actions/workflows/ci.yml)
![platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## What it does

- **Single dashboard** for all concurrent agent sessions — Claude Code
  today, Aider / Gemini CLI / your own tools tomorrow.
- **Orange "needs you"** banner + system notification the moment a
  session hits a permission prompt.
- **Click to jump** straight to that session's iTerm tab, or activate
  the JetBrains window it started from.
- **Keyboard-first**: open the popover, `↑ ↓` to pick, `⏎` to jump,
  `esc` to close.
- **Right-click** the menu bar icon for Quit.
- **Zero telemetry.** Everything stays on your machine.

## Status model

| color    | status      | meaning                                          |
| -------- | ----------- | ------------------------------------------------ |
| 🟠 orange | waiting     | blocked on a permission prompt — needs you now   |
| 🔵 blue   | running     | actively executing a tool (Bash, Edit, …)        |
| 🟣 purple | thinking    | you submitted; agent is reasoning before tools   |
| 🟢 green  | idle        | turn finished, waiting for your next prompt      |

## Supported agents

| agent       | adapter                                          |
| ----------- | ------------------------------------------------ |
| Claude Code | [`hooks/claude/`](./hooks/claude)                |
| _others_    | write one in ~50 lines — see [hooks/README.md](./hooks/README.md) |

AgentPulse itself is agent-agnostic: the daemon only knows a simple
HTTP/JSON event format ([docs/api.md](./docs/api.md)). Anything that
can `curl` can report in.

## Requirements

- macOS 14 (Sonoma) or newer — macOS 26 (Tahoe) unlocks the full Liquid Glass UI
- Swift 5.9+ (Xcode 15+) to build
- [`jq`](https://jqlang.github.io/jq/) for the Claude hook installer (`brew install jq`)
- An agent that supports hooks (Claude Code today)

## Install

```bash
git clone https://github.com/fanook/agentpulse.git
cd agentpulse

# 1. Build AgentPulse.app
./scripts/make-app.sh

# 2. Move it somewhere permanent
mv build/AgentPulse.app /Applications/

# 3. Launch once so macOS registers the bundle + grants notification perms
open /Applications/AgentPulse.app

# 4. Wire in the Claude adapter (merges into ~/.claude/settings.json, preserves existing entries)
./hooks/claude/install.sh
```

Auto-start at login: **System Settings → General → Login Items → add AgentPulse.app**.

## Architecture

```
┌──────────────┐  agent hook   ┌────────────┐  POST /hook   ┌──────────────────────┐
│  Claude Code ├──────────────►│ report.sh  ├──────────────►│  AgentPulse.app      │
│    (native)  │  JSON on stdin│ (bash)     │ + auth token  │  127.0.0.1:9876      │
└──────────────┘               └────────────┘               │                      │
                                                            │  HTTPServer          │
┌──────────────┐               ┌────────────┐               │   ▼                  │
│   Aider /    │               │ adapter.sh │               │  SessionStore ──────┼──► ~/Library/.../sessions.json
│   Gemini /   ├──────────────►│ (your own) ├──────────────►│   ▼                  │
│   your tool  │               └────────────┘               │  MenuBarContent      │
└──────────────┘                                            │   ▼                  │
                                                            │  NSStatusItem +      │
                                                            │  NSPopover           │
                                                            │   ▼                  │
                                                            │  Jumper ────────────┼──► iTerm AppleScript,
                                                            │                      │    tmux, JetBrains
                                                            │  Notifier ──────────┼──► system banner
                                                            └──────────────────────┘
```

See [docs/api.md](./docs/api.md) for the event format.

### Local HTTP bridge

AgentPulse binds to `127.0.0.1` only; the actual port is written to
`~/.pulse/port` (falls through 9876 → 9895 on conflict).  A random
48-char token is generated on first launch, stored at `~/.pulse/token`
(mode 0600), and required as `X-AgentPulse-Token` on `POST /hook`.

`GET /health` is unauthenticated and returns `ok` when the daemon is up.

## Privacy

- No data is sent off your machine. The HTTP server only listens on
  loopback (`127.0.0.1`), and there is no analytics or phone-home code.
- AgentPulse persists the following locally:
  - `~/Library/Application Support/AgentPulse/sessions.json` — session
    list, cwd, terminal hints, and last known activity.
  - `~/Library/Logs/AgentPulse/hooks.log` — a line per hook event.
  - `~/.pulse/port` and `~/.pulse/token` — bridge coordinates for hooks.
- The session list may include the absolute path of the directory you
  ran the agent from. If that's sensitive, remove the row with the
  hover `×` and it's gone for good.

## Uninstall

```bash
./hooks/claude/uninstall.sh                         # remove AgentPulse hooks from settings.json
rm -rf /Applications/AgentPulse.app
rm -rf "$HOME/Library/Application Support/AgentPulse"
rm -rf "$HOME/Library/Logs/AgentPulse"
rm -rf "$HOME/.pulse"
```

## Development

```bash
swift build                    # debug build
swift test                     # run unit tests
swift run agentpulse           # run without bundling (no system notifications)
./scripts/make-app.sh          # release build wrapped in AgentPulse.app
./scripts/fake-claude.sh       # scripted event sequence (reads token automatically)
./scripts/generate_icon.swift Resources   # regenerate AppIcon.icns
```

### Layout

| path                                  | purpose                                    |
| ------------------------------------- | ------------------------------------------ |
| `Sources/AgentPulse/`                 | SwiftUI + AppKit app                       |
| `Tests/AgentPulseTests/`              | XCTest unit tests                          |
| `hooks/claude/`                       | Claude Code adapter (report/install/uninstall) |
| `hooks/README.md`                     | how to write a new agent adapter           |
| `docs/api.md`                         | the HTTP/JSON event format                 |
| `scripts/make-app.sh`                 | build + bundle                             |
| `scripts/generate_icon.swift`         | AppKit-based `.icns` generator             |
| `scripts/fake-claude.sh`              | end-to-end smoke test                      |
| `Resources/AppIcon.icns`              | checked-in app icon                        |

## Known limitations

- **JetBrains terminals**: the IDEs don't expose an API to focus a
  specific terminal tab. AgentPulse can bring the IDE window to the
  front; you'll still need to click the correct tab.
- If an agent is killed ungracefully (no `SessionEnd` fires), its row
  sticks around until you dismiss it with the hover `×`.
- macOS icon caches are stubborn — if a notification shows a stale icon
  after you rebuild, `killall NotificationCenter` and relaunch AgentPulse.

## Contributing

PRs welcome. Please:

1. `swift test` passes.
2. New user-visible strings go through `L10n` (zh-Hans + en today).
3. No data leaves the machine without an explicit opt-in.
4. New agent adapters live under `hooks/<agent>/` and follow the
   contract in [docs/api.md](./docs/api.md).

## License

MIT — see [LICENSE](./LICENSE).
