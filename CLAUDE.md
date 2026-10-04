# nod

> Working name. Rename freely (binary, D-Bus names, extension UUID).

A GNOME companion for Claude Code: a small pill at the top centre of the screen that shows what every Claude Code session is doing and lets me Allow/Deny permission requests without switching to the terminal. Inspired by [Coucou](https://github.com/Louis-CFM/coucou) (macOS/Windows), rebuilt for GNOME on Linux.

## Environment

- GNOME Shell: `<fill in from: gnome-shell --version>` on Wayland
- Distro: `<fill in>`
- Go: current stable
- Explain GNOME Shell / GJS APIs briefly when you first use them.

## Architecture

```
Claude Code
 └ hook event (JSON on stdin) → `nod hook`
    └ unix socket → `nod daemon`   (all state + logic)
       └ D-Bus → GNOME Shell extension   (UI only)
```

One Go binary, `nod`, with subcommands:

- `nod hook`: invoked by Claude Code for every registered event. Reads the event JSON from stdin and forwards it to the daemon. Only for `PermissionRequest` does it wait for a decision and print it. Fast and stateless.
- `nod daemon`: long-running, run as a systemd user service. Holds session state and the approval queue, and exposes the D-Bus API.
- `nod install` / `nod uninstall`: merge or remove our hook entries in `~/.claude/settings.json`.
- `nod status`, `nod approve <id>`, `nod deny <id>`: debug CLI, so the approval path can be tested before any UI exists.

The GNOME Shell extension (`extension/`) is GJS with ES modules. It renders state and sends Approve/Deny over D-Bus. No business logic.

Why the split: extension code runs inside gnome-shell. An exception or hang there can break the desktop, and on Wayland a shell crash ends the session. Keep the extension thin; all logic and I/O lives in Go.

## Non-negotiable rules

1. **Never block or break Claude Code.** In `nod hook`, every failure path (daemon not running, connect timeout, bad JSON, panic) exits 0 with empty stdout. Recover panics. Stdout contains only the decision JSON or nothing.
2. **Never write the real `~/.claude/settings.json` without a backup, a printed diff, and confirmation.** Tests use a temp `$HOME`. Install is idempotent. Uninstall removes only our entries and leaves every other hook untouched.
3. **During development, don't install hooks globally.** Register them in a separate scratch project's `.claude/settings.local.json`, so the Claude Code session building this repo never runs through a half-built hook.
4. **Extension hygiene:** no synchronous I/O and no polling loops. `disable()` destroys every actor, disconnects every signal, and drops every D-Bus proxy and name watch.
5. **Minimal dependencies:** Go stdlib plus `github.com/godbus/dbus/v5`. Ask before adding anything else.
6. **No Coucou assets:** don't copy its name, Mochi character, icon, sounds, or media (all rights reserved). Its code is MIT; if any code is ported, keep the copyright notice.

## Claude Code hooks contract

Source of truth: https://code.claude.com/docs/en/hooks. The schema evolves, so re-check it when something behaves unexpectedly instead of guessing.

- Command hooks receive the event JSON on stdin. Common fields: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode` (not on every event). Tool events add `tool_name`, `tool_input`, `tool_use_id`.
- Register hooks in exec form: `command` is an absolute path, `args: ["hook"]`. There is no shell, so `~` won't expand. Omitting `matcher` matches everything.
  ```json
  {"hooks": {"PermissionRequest": [{"hooks": [
    {"type": "command", "command": "/home/USER/.local/bin/nod", "args": ["hook"]}
  ]}]}}
  ```
- Exit 0 with empty stdout means "no opinion" and the normal flow continues. Staying silent on `PreToolUse` doesn't approve anything; we are only observers there.
- `PermissionRequest` is the only event where we return a decision:
  ```json
  {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}
  ```
  `behavior` is `allow` or `deny`. Exit code 2 is not honoured for this event, so always exit 0 and use JSON. Check the docs for the deny-message field before adding one.
- The terminal prompt can still be answered while our hook waits. When the hook process goes away (answered in the terminal, timed out, session ended), the daemon must drop the pending approval. Tie each approval's lifetime to the hook's socket connection.
- The default command-hook timeout is 600 s. On timeout, output is discarded and the normal flow continues.
- `Notification` with `permission_prompt` only fires after about 6 s, and not at all if a `PermissionRequest` hook answered first, so ignore it. Use `idle_prompt` for "waiting for your input".
- All `SessionEnd` hooks share a 1.5 s budget, so the hook must be fire-and-forget there.
- Hooks run without a controlling terminal (no `/dev/tty`).

Events registered for the MVP: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SessionEnd`.

## Session state

Keyed by `session_id`. The label is the basename of `cwd`.

| Event | State |
|---|---|
| `SessionStart` | idle |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working (`PreToolUse` also sets the current activity: tool name plus a short summary) |
| `PermissionRequest` | needs_approval (adds a queue entry) |
| `Notification` with `idle_prompt` | needs_input |
| `Stop` | done |
| `SessionEnd` | removed |

- Expire sessions with no events for a few minutes, because a crashed `claude` never sends `SessionEnd`.
- The overall indicator shows the most urgent state across all sessions: needs_approval > needs_input > working > done > idle.

## IPC

### Hook ↔ daemon

- Socket path is `$XDG_RUNTIME_DIR/nod/nod.sock`. The directory is 0700 and the socket 0600. The daemon checks the peer UID with `SO_PEERCRED` and rejects any other user.
- Messages are newline-delimited, versioned JSON: `{"v":1,"type":"event","event":<raw hook JSON>}`.
- Observational events: connect with about a 100 ms timeout, write, close. Never wait for a reply.
- `PermissionRequest`: send, then block reading one line, `{"v":1,"decision":"allow"|"deny"}`. On EOF or any error, exit 0 silently.

### Daemon ↔ extension (D-Bus session bus)

- Name `io.github.jiisanda.nod`, object path `/io/github/jiisanda/nod`, interface `io.github.jiisanda.nod1`.
- Methods: `GetState() → s` (JSON snapshot), `Approve(s id)`, `Deny(s id)`.
- Signal: `StateChanged(s)`, carrying the full JSON snapshot. One signal type keeps the UI simple.
- Approval ids are random 128-bit hex. An unknown or stale id returns a D-Bus error, never a panic.
- JSON-in-a-string is fine for the MVP; switch to typed D-Bus signatures only if needed.

### Threat model

Same-UID processes are trusted, since they can already edit `settings.json`. The goal is that no other user, and nothing over the network, can answer approvals. No TCP listeners, no telemetry.

## GNOME Shell extension notes

- UUID `nod@jiisanda.github.io`. The `shell-version` list in `metadata.json` must include my GNOME version.
- GNOME 45+ uses ES modules: `import * as Main from 'resource:///org/gnome/shell/ui/main.js'` and `export default class extends Extension`.
- Placement: an `St` actor added through `Main.layoutManager` chrome (`addChrome` / `addTopChrome`; check which behaves better over fullscreen windows), centred on the primary monitor and re-positioned on `monitors-changed`. It is clickable but never grabs keyboard focus.
- D-Bus: use `Gio.DBusProxy.makeProxyWrapper(xml)`, and `Gio.bus_watch_name` to show or hide the UI as the daemon appears or disappears.
- Logs: `journalctl -f -o cat /usr/bin/gnome-shell`.
- Dev loop: always test in a nested shell, never by reloading the real session. GNOME ≤48: `dbus-run-session -- gnome-shell --nested --wayland`. GNOME 49+: `dbus-run-session gnome-shell --devkit`. If neither works, check https://gjs.guide/extensions/ for the current command.

## Repo layout

```
cmd/nod/                 main + subcommands
internal/hook/             stdin → socket client, decision output
internal/daemon/           socket server, peer-cred check
internal/state/            session store, state machine, approval queue
internal/settings/         settings.json merge / backup / diff / uninstall
internal/dbusapi/          godbus export
extension/nod@jiisanda.github.io/
    metadata.json  extension.js  dbus.js  stylesheet.css
packaging/nod.service    systemd user unit
testdata/hooks/            real hook payloads captured from Claude Code
```

## Commands

- Build and check: `go build ./cmd/nod`, `go test ./...`, `go vet ./...`. `gofmt -l .` must print nothing.
- Daemon in the foreground: `./nod daemon -v`
- Replay an event: `./nod hook < testdata/hooks/permission_request.json`
- Inspect D-Bus: `busctl --user introspect io.github.jiisanda.nod /io/github/jiisanda/nod`
- Watch signals: `gdbus monitor --session --dest io.github.jiisanda.nod`
- Extension: symlink `extension/nod@jiisanda.github.io` into `~/.local/share/gnome-shell/extensions/`, then `gnome-extensions enable nod@jiisanda.github.io` inside the nested shell.

## Milestones

Work in order. Each one ends with something I can verify by hand.

1. **Hook + daemon, logging only.** Register hooks by hand in the scratch project and save real payloads into `testdata/hooks/`. Done when a real session's events show up in the daemon log, and Claude Code behaves the same with the daemon stopped.
2. **State + approvals via CLI.** Done when `nod status` lists sessions, `nod approve <id>` answers a real permission request, and answering in the terminal instead clears the pending entry.
3. **D-Bus API.** Done when `busctl`/`gdbus` can read state and approve.
4. **Extension MVP.** A pill at the top centre: hidden when there are no sessions, shows the most urgent state, and expands to list pending approvals with Allow/Deny.
5. **`nod install` / `nod uninstall`.** Backup, diff, confirm, with golden-file tests.
6. **Later:** character and animations, sounds, click-to-focus terminal, multi-monitor, packaging (deb/AUR), extensions.gnome.org submission.

## Working agreements

- Small commits. Run tests, `go vet`, and `gofmt` before calling anything done.
- Every bug fix comes with a test.
- When unsure about a hook detail, check the docs URL above rather than guessing.
