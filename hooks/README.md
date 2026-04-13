# AgentPulse hooks

AgentPulse monitors multiple CLI agents through a single local HTTP bridge.
Each agent has its own subdirectory with bash scripts that translate the
agent's native hook/event system into AgentPulse's generic JSON protocol
(`POST /hook`). See [../docs/api.md](../docs/api.md) for the wire format.

## Built-in adapters

| directory     | agent        | notes                                    |
| ------------- | ------------ | ---------------------------------------- |
| `claude/`     | Claude Code  | uses `~/.claude/settings.json` hooks     |

## Adding support for another agent

1. Create `hooks/<agent>/` with at least `report.sh`, `install.sh`, `uninstall.sh`.
2. `report.sh` reads the agent's event payload, reshapes it to AgentPulse's
   JSON, and `curl`s to `127.0.0.1:$(cat ~/.pulse/port)/hook` with header
   `X-AgentPulse-Token: $(cat ~/.pulse/token)`.
3. Always set `agent` to a short lowercase identifier (e.g. `"aider"`).
4. `install.sh` / `uninstall.sh` wire the script into the agent's config.

Pull requests welcome.
