# Developing AgentPulse

## Architecture

```
┌──────────────┐  Claude hook   ┌────────────┐  POST /hook   ┌───────────────────────┐
│  Claude Code ├───────────────►│ report.sh  ├──────────────►│  AgentPulse.app       │
│  (any tty)   │  JSON on stdin │ (bash)     │ + auth token  │  127.0.0.1:9876       │
└──────────────┘                └────────────┘               │                       │
                                                             │  HTTPServer           │
┌──────────────┐                ┌────────────┐               │   ▼                   │
│  Aider /     │                │ adapter.sh │               │  SessionStore ────────┼──► ~/Library/.../sessions.json
│  your agent  ├───────────────►│ (your own) ├──────────────►│   ▼                   │
└──────────────┘                └────────────┘               │  NotchPresenter       │
                                                             │  (DynamicNotchKit)    │
                                                             │   ▼                   │
                                                             │  Menu-bar NSStatusItem│
                                                             │   ▼                   │
                                                             │  Jumper ──────────────┼──► iTerm AppleScript,
                                                             │                       │    tmux send-keys,
                                                             │                       │    JetBrains activate
                                                             └───────────────────────┘
```

- The app is agent-agnostic: it only understands a simple HTTP/JSON event envelope (see [api.md](./api.md)).
- Sessions are rendered in a Dynamic-Island-style capsule (`NotchPresenter` + [`DynamicNotchKit`](https://github.com/MrKai77/DynamicNotchKit)); non-notch Macs fall back to a floating banner at the top of the main screen.
- Status colors, waiting highlights, and the cream/coral theme all live in `MenuBarView.swift`'s `ClaudeTheme`.

## Event protocol

See [api.md](./api.md) for the request format, required fields, and the exact list of events.

The bundled Claude Code adapter is in [`hooks/claude/`](../hooks/claude). For other agents, drop a new directory under `hooks/<agent>/` with `report.sh`, `install.sh`, `uninstall.sh`. See [`hooks/README.md`](../hooks/README.md) for the contract.

## Local HTTP bridge

- Binds to `127.0.0.1` only. Port is written to `~/.pulse/port` each launch (default 9876, falls through 9876–9895 on conflict).
- A 48-char hex token is generated on first launch at `~/.pulse/token` (mode `0600`, directory `0700`).
- Every `POST /hook` request must carry `X-AgentPulse-Token: <that token>`.
- `GET /health` returns `ok` unauthenticated — useful for probes.

## Build & run

```bash
swift build                       # debug build
swift test                        # run unit tests
swift run agentpulse              # run without bundling (dev-only)
./scripts/make-app.sh             # release build wrapped in AgentPulse.app
./scripts/make-dmg.sh             # build + wrap in a drag-to-install DMG
./scripts/fake-claude.sh          # scripted event sequence (reads token automatically)
./scripts/generate_icon.swift Resources   # regenerate AppIcon.icns
VERSION=0.1.0 ./scripts/make-app.sh       # override version string
```

The version string is picked up from the current git tag when building, so tag → push → CI produces a matching DMG + About pane version.

## Release

```bash
git tag v0.1.0
git push --tags
```

`.github/workflows/release.yml` builds an unsigned DMG on macos-14 and publishes it to the matching GitHub Release.

## Layout

| path                                  | purpose                                        |
| ------------------------------------- | ---------------------------------------------- |
| `Sources/AgentPulse/`                 | SwiftUI + AppKit app                           |
| `Tests/AgentPulseTests/`              | XCTest unit tests                              |
| `hooks/claude/`                       | Claude Code adapter (report / install / uninstall) |
| `hooks/README.md`                     | how to write a new agent adapter               |
| `docs/api.md`                         | HTTP / JSON event protocol                     |
| `docs/developing.md`                  | this file                                      |
| `scripts/make-app.sh`                 | build + .app bundle                            |
| `scripts/make-dmg.sh`                 | build + DMG                                    |
| `scripts/fake-claude.sh`              | end-to-end smoke test                          |
| `scripts/generate_icon.swift`         | AppKit-based `.icns` generator                 |
| `install.sh` / `uninstall.sh`         | one-shot user installer / uninstaller          |
| `Resources/AppIcon.icns`              | checked-in app icon                            |

## Known limitations

- **JetBrains / VS Code / Warp terminals**: no per-tab scripting API. AgentPulse activates the app window; you still click the right tab.
- **Ungraceful agent exit**: if a session dies without firing `SessionEnd`, its row persists until dismissed with the hover `×`.
- **Unsigned build**: every upgrade walks through the right-click → Open Gatekeeper dance until signing+notarize is added.

## Contributing

- `swift test` must pass.
- New user-visible strings go through `L10n`.
- No data leaves the machine without an explicit opt-in.
- New agent adapters live under `hooks/<agent>/` and follow the contract in [api.md](./api.md).
