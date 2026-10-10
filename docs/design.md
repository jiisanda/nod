# nod design

Living document. Each section records decisions we've agreed on, the reasoning, and what's still open. CLAUDE.md holds the working rules; this file holds the *why*. Where they disagree, this file is newer and CLAUDE.md should be updated.

Status per planning step:

| # | Topic | Status |
|---|---|---|
| 1 | Goals and non-goals | decided |
| 2 | Hooks contract check | decided (experiment run 2026-10-04; three small verify items left) |
| 3 | Components and boundaries | decided |
| 4 | Data model | decided |
| 5 | Protocols | open |
| 6 | Lifecycles and failure modes | open |
| 7 | Security | open |
| 8 | Pill UX | open |
| 9 | Testing strategy | open |
| 10 | Milestone plan | open |

Dev environment: GNOME Shell 50.1 (Wayland), Go 1.27.1.

---

## 1. Goals and non-goals

### Audience

nod is for anyone running Claude Code on Linux, not just one machine. Consequences:

- **GNOME is the first frontend, not the only one.** The daemon and its D-Bus API are desktop-neutral, so other frontends (KDE plasmoid, waybar module, `nod tui`) can be built against the same interface later. All logic stays in the daemon; frontends only render and send decisions.
- **No hard systemd dependency.** We ship a systemd user unit, but `nod daemon` must work equally well started from XDG autostart or by hand. No systemd-only APIs.
- **The D-Bus interface is a public contract.** Versioned in the interface name (`io.github.jiisanda.nod1`). After first release, changes are additive only; breaking changes mean `nod2`.

### MVP scope

- Show every running Claude Code session and what it is doing.
- Answer permission requests from the pill with the full decision set:
  - **Allow**
  - **Deny**, with a message sent back to Claude (e.g. "Denied from nod").
  - **Allow and don't ask again**, by returning one of the `permission_suggestions` Claude Code sent with the request as `updatedPermissions`. This covers directory- and pattern-scoped rules.
- Many concurrent sessions: the pill shows the most urgent one; arrows cycle through the rest.

### Non-goals for the MVP

- Mascot, animations, sounds, polished visual design. (Planned, after the MVP.)
- Frontends other than GNOME Shell.
- Click-to-focus terminal, multi-monitor placement, packaging, extensions.gnome.org submission.
- Inventing permission rules. nod only offers back suggestions Claude Code itself provided.

### Lightweight is a design constraint

nod sits in the path of every tool call and runs all day. Budgets, to be measured rather than assumed:

| Piece | Budget | How |
|---|---|---|
| `nod hook` | < 10 ms wall per event | Go starts in about 2 ms. Observational events: connect, write, exit; never wait for a reply. |
| `nod daemon`, idle | 0% CPU, < 15 MB RSS | Purely event-driven. No polling, no tickers. Session expiry uses a single timer armed for the next deadline. |
| `nod daemon`, busy | negligible | `StateChanged` is coalesced to at most ~10 per second, so tool-call bursts don't flood D-Bus or the shell. |
| Extension | no work when nothing changes | Redraws only on signals; no timers. The actor is hidden (not transparent) when there are no sessions. Future animations must stop while hidden. |

The hot path is `PreToolUse`/`PostToolUse`: two process spawns per tool call. That is why `nod hook` must never do more than connect, write, exit.

---

## 2. Claude Code hooks contract

Sources: https://code.claude.com/docs/en/hooks (read 2026-10-04, through a summarising fetch) and an experiment run on 2026-10-04 with Claude Code in `scratch/` (raw logs not committed; one payload per event saved in `testdata/hooks/`). **Where the experiment and the docs summary disagree, the experiment wins.** The summary got several details wrong, so treat anything below marked *docs only* as unconfirmed.

### What real payloads look like

Common fields seen on most events: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus newer ones not in our notes: `prompt_id` (one per user prompt), `scratchpad_dir`, `effort`. `permission_mode` is sent per event and can change mid-session (we saw `auto` → `default` within one session).

| Event | Useful fields |
|---|---|
| `SessionStart` | `source` (`startup`), `model` |
| `UserPromptSubmit` | `prompt` (the user's text) |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id`, sometimes `agent_id` |
| `PermissionRequest` | `tool_name`, `tool_input`, `permission_suggestions`. **No `tool_use_id`.** |
| `PostToolUse` | `tool_name`, `tool_input`, `tool_use_id`, `tool_response`, `duration_ms` |
| `Notification` | `notification_type` (`permission_prompt`, `idle_prompt`), `message` |
| `Stop` | `last_assistant_message` (Claude's final reply; nice to show in the pill later) |
| `SessionEnd` | `reason` (`prompt_input_exit`) |

### Findings

**1. `PermissionRequest` has no `tool_use_id`.** To link a request to its tool call, match it to the `PreToolUse` that arrives about 40 ms earlier in the same session with the same `tool_name` and `tool_input`. That pairing gives us the `tool_use_id`, which we need to spot the matching `PostToolUse`.

**2. `permission_suggestions` are structured objects, not rule strings.** Real example:

```json
"permission_suggestions": [
  {"type": "addDirectories", "directories": ["/home/jiisanda/projects/nod/scratch"], "destination": "session"},
  {"type": "setMode", "mode": "acceptEdits", "destination": "session"}
]
```

So "allow and don't ask again" may mean adding a directory, switching mode, or adding rules, each with a destination (`session` here; probably also project/user/local). The docs summary showed `updatedPermissions` as a string array; given the input shape, it most likely takes these same objects. **Verify** before milestone 2 by reading the docs page directly and by a test that sends one suggestion back and checks it takes effect.

**3. Allowing in the terminal does not stop our hook.** (Tests 2 and 5.) The hook kept running after the user pressed Yes. `PostToolUse` arrived within about a second, carrying the `tool_use_id` from finding 1. A decision the hook printed later was ignored: a late `deny` after a terminal allow did nothing, and the file was created.

**4. Denying in the terminal kills our hook immediately.** (Tests 3 and 4.) The hook got `SIGTERM` at the moment the user pressed No. No other event fired afterwards: no `Stop`, no failure event. The session was silent until the user's next message. Because the hook is killed, a late `allow` after a terminal deny can never be sent (test 4: the file was not created).

**5. Exiting `claude` also kills a waiting hook, and `SessionEnd` doesn't always fire.** One session's hook got `SIGTERM` when the user left the session, and that session never sent `SessionEnd`. Expiring silent sessions is required, not optional.

**6. `PreToolUse` is not always followed by `PostToolUse`.** We saw `PreToolUse` with no matching `PostToolUse` when the tool failed (`cat` of a missing file), and for tool calls carrying an `agent_id` that ran without the user asking. Those were probably background or speculative agents in the same session (Claude Code ran `touch probe2.txt` before the user had typed it). So a dangling `PreToolUse` must not leave a session looking "working" forever, and events with an `agent_id` must not count as the main session moving on.

**7. In `auto` mode there is no `PermissionRequest`.** Tool calls were auto-approved without one, as expected. Nothing for nod to do there except show activity.

**8. `Notification`/`permission_prompt` fires about 6 s after a request when our hook gives no decision,** and `idle_prompt` fired about 60 s after `Stop`. Both match the notes.

### Approval lifetime (decided)

An approval stays pending until the first of:

| Trigger | Meaning | What the daemon does |
|---|---|---|
| The user clicks in the pill | nod decides | Send the decision on the hook connection |
| The hook connection closes (`SIGTERM`, timeout, `claude` exited) | Denied in the terminal, timed out, or session gone | Remove the approval |
| `PostToolUse` with the paired `tool_use_id` | Allowed in the terminal | Remove the approval and close the hook connection without a decision |
| `UserPromptSubmit`, `Stop` or `SessionEnd` for the session (main agent, no `agent_id`) | Session moved on | Same as above (safety net) |

That resolves the "deny-in-terminal gap" from earlier planning: there is no gap, because a terminal deny closes the hook connection, which the daemon notices immediately. The two terminal paths (allow and deny) are both covered within about a second.

Safety property, confirmed by tests 4 and 5: a decision that arrives after the terminal prompt was answered is either impossible (after a deny, the hook is dead) or ignored (after an allow). nod clicking a stale card cannot override what the user chose in the terminal.

### Output (docs only, partly unconfirmed)

```json
{"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
  "behavior": "allow" | "deny",
  "updatedPermissions": [ ... ],
  "message": "..."
}}}
```

- `behavior` confirmed by the experiment (the probe's `allow` and `deny` were honoured when sent before the terminal answer).
- `message`: shown to the user; we use it on deny. Docs only.
- `updatedPermissions`: only applied on `allow`; shape to be verified (finding 2).
- Multiple `PermissionRequest` hooks: first deny wins; permissions merge; last message wins. Docs only.
- Timeout 600 s by default; on timeout output is discarded and the normal prompt continues. Docs only.

### Still to verify

- The `updatedPermissions` shape (finding 2).
- Whether `PostToolUseFailure` (or similar) exists and fires for failed tools. If so, register it so failed tools also resolve "working" activity.
- What `agent_id` events mean exactly (subagents vs. speculative runs) and whether subagents can raise their own `PermissionRequest`.

### Other contract points (unchanged from CLAUDE.md)

- Default command-hook timeout is 600 s for `PermissionRequest`.
- `Notification`/`permission_prompt` is ignored; `idle_prompt` means "waiting for input".
- `SessionEnd` hooks share a 1.5 s budget: fire-and-forget.
- Hooks have no controlling terminal.

---

## 3. Components and boundaries

```
 Claude Code ──stdin──▶ nod hook ──unix socket──▶ nod daemon ◀──D-Bus──┬─ GNOME extension
                         (relay)                  (all logic)          ├─ nod status / approve / deny
                                                                       └─ (future: KDE, waybar, tui)
 nod install ──▶ ~/.claude/settings.json   (separate; never talks to the daemon)
```

Each component has one job and an explicit list of things it must never do.

### `nod hook`: relay

- **Owns:** reading stdin; reading `hook_event_name` (the only field it looks at) to decide whether to wait; forwarding the raw payload; for `PermissionRequest`, printing the decision it receives.
- **Never:** keeps state, writes files, retries, logs to stdout, starts the daemon, interprets the payload beyond `hook_event_name`.
- Any failure: exit 0, empty stdout.

### `nod daemon`: all logic

- **Owns:** session and approval state; pairing `PermissionRequest` with its `PreToolUse`; the approval lifetime rules (section 2); session expiry; coalescing state updates; formatting every string a frontend displays; the D-Bus API.
- **Structure:** a pure core (`internal/state`) with no I/O: events, clicks and the current time go in, new state comes out. All the rules from the experiment live there and are unit-tested against `testdata/hooks/` without sockets or sleeps. A thin outer layer (`internal/daemon`, `internal/dbusapi`) does socket and D-Bus I/O. One goroutine owns the state; socket handlers and D-Bus methods send it messages, so events are processed strictly in order and there are no locks around state.
- **Never:** makes a decision the user didn't click; reads transcripts; touches `settings.json`; executes anything.

### Frontends (GNOME extension first)

- **Owns:** rendering the snapshot, positioning, turning clicks into D-Bus calls.
- **Never:** parses hook payloads, keeps its own model of sessions, does file I/O, runs timers other than UI animation.
- The daemon pre-formats display text (activity summaries, labels, option labels), so all frontends show the same thing and contain no logic.

### `nod status` / `nod approve` / `nod deny`

A D-Bus client using the same public API as the extension. It is the first frontend and exercises the API before any UI exists.

### `nod install` / `nod uninstall`

- **Owns:** nod's entries in `~/.claude/settings.json`, with backup, diff and confirmation.
- Independent of the daemon.

### Decisions

1. **The CLI talks D-Bus, not the socket.** One control API to build and secure. Consequence: CLAUDE.md milestones 2 and 3 merge, since D-Bus must exist before `nod approve` works. The unix socket carries only hook traffic.
2. **nod never decides on its own.** No auto-allow rules inside nod. Standing permissions live in Claude Code's own rules, which "Allow and don't ask again" writes to. nod is a remote control, not a policy engine.
3. **No persisted state.** On daemon restart, sessions reappear with their next event. Waiting hooks lose their connection and exit silently, so the terminal prompt still works.
4. **The hook never starts the daemon.** systemd or XDG autostart starts it. If it isn't running, nod has no opinion and Claude Code behaves normally.

---

## 4. Data model

### Internal state (daemon only)

**Session**, keyed by `session_id`:

| Field | Source |
|---|---|
| `label` | Basename of `cwd`, disambiguated (below) |
| `cwd`, `permission_mode` | Latest event (mode can change mid-session) |
| `base_state` | `idle` / `working` / `needs_input` / `done`, set by events |
| `activity` | Tool + short summary (`Bash · touch probe2.txt`), or none |
| `last_event_at` | Latest event; for the fallback expiry |
| `claude_pid` | Parent PID reported by the hook; watched for exit (below) |
| `recent_pre_tool_uses` | Small ring buffer of recent `PreToolUse` (tool name, input, `tool_use_id`), used only for pairing |

**Approval**, one per pending `PermissionRequest`:

| Field | Notes |
|---|---|
| `id` | Random 128-bit hex; what frontends send back |
| `session_id`, `tool_use_id` | `tool_use_id` from pairing; may be empty if pairing fails (safety-net rules still resolve it) |
| `tool_name`, `tool_input` | Kept in full |
| `suggestions` | Raw `permission_suggestions`, sent back verbatim when chosen |
| `conn` | The hook's connection; closing it removes the approval |

**`needs_approval` is derived, never stored.** A session needs approval iff it has at least one open approval; `overall` is derived from sessions. State and queue cannot disagree.

### Transitions

| Event | Effect |
|---|---|
| `SessionStart` | Create session, `idle` |
| `UserPromptSubmit` | `working`; clear activity; close open approvals (safety net) |
| `PreToolUse` | `working`; set activity; remember for pairing |
| `PostToolUse` | `working`; clear activity; close the approval paired with this `tool_use_id` |
| `PermissionRequest` | Pair with a remembered `PreToolUse` (same session, tool name, input); add approval |
| `Notification` `idle_prompt` | `needs_input` |
| `Notification` `permission_prompt` | Ignored |
| `Stop` | `done`; clear activity; close open approvals (safety net) |
| `SessionEnd` | Remove session |
| Any event with `agent_id` | Only updates `last_event_at`; never changes state. Its `PreToolUse` is still remembered for pairing in case a subagent asks for permission. |

"Close an approval" means: remove it and close the hook connection without a decision (the hook exits silently).

**Labels:** basename of `cwd`. If two sessions share it, use `parent/base` (`work/api`, `personal/api`); if they share the directory, append a short id (`api #3f2a`).

### Session expiry

The experiment showed `SessionEnd` doesn't always fire. Primary mechanism: **watch the `claude` process.** The hook sends its parent PID (the `claude` process, since exec-form hooks have no shell in between). The daemon opens a `pidfd` for it (`pidfd_open(2)`, Linux 5.3+, reachable from the Go stdlib via a raw syscall) and polls it in the event loop; it becomes readable when the process exits, and the session is removed immediately, crashes included. No polling timers.

Fallback: remove a session after 30 minutes with no events and no open approvals (covers PID lookup failures, PID namespaces, unusual launchers).

**Verify:** that the hook's parent PID is the long-lived `claude` process for exec-form hooks (our probe ran through bash; nod won't).

### Snapshot (what frontends receive)

```json
{
  "v": 1,
  "overall": "needs_approval",
  "sessions": [
    {
      "id": "5471d4ed-…",
      "label": "scratch",
      "state": "needs_approval",
      "activity": {"tool": "Bash", "summary": "touch probe2.txt"},
      "mode": "default",
      "since": 1759600009000,
      "approvals": [
        {
          "id": "9f3c…",
          "tool": "Bash",
          "summary": "touch probe2.txt",
          "detail": "touch probe2.txt",
          "options": [
            {"id": "allow", "label": "Allow"},
            {"id": "s0",    "label": "Allow, and don't ask again for files in scratch/ (this session)"},
            {"id": "s1",    "label": "Allow, and accept all edits (this session)"},
            {"id": "deny",  "label": "Deny"}
          ]
        }
      ]
    }
  ]
}
```

- **The daemon sorts sessions:** most urgent first, then oldest pending approval, then most recent activity. Frontends show `sessions[0]`; arrows step through the list.
- **Options are a daemon-built list.** Frontends send back only `(approval id, option id)`. New suggestion types need no frontend change.
- **`summary` is short; `detail` is never truncated.** You always see the whole command before you can allow it.
- Raw payloads, connections and the pairing buffer never leave the daemon.
- Consumers ignore unknown fields; adding fields doesn't bump `v`.

Open (steps 7 and 8): how `detail` presents large `Write`/`Edit` content (path + scrollable full view vs. diff preview).

---

## Pending CLAUDE.md updates

Confirmed by the experiment; apply when we next touch CLAUDE.md:

- "Claude Code hooks contract": replace "When the hook process goes away (answered in the terminal…) the daemon must drop the pending approval" with the approval lifetime table in section 2. Note `PermissionRequest` has no `tool_use_id`.
- "Hook ↔ daemon": the daemon may close a waiting `PermissionRequest` connection without a decision.
- "Environment": GNOME Shell 50.1, Go 1.27.1, distro.
- Architecture: note that the D-Bus API is desktop-neutral and other frontends are expected; systemd is optional.
- Architecture: the CLI is a D-Bus client; milestones 2 and 3 merge. nod never auto-decides; no persisted state; the hook never starts the daemon.
- Decision set: `allow`, `deny` + message, `allow` + `updatedPermissions` from suggestions (structured objects, not strings).
- "Session state": replace the table and expiry note with section 4 (derived `needs_approval`, `agent_id` rule, pidfd expiry with 30 min fallback).
- "Session state" (old note): `Stop`/`idle_prompt` must clear dangling `PreToolUse` activity; events with `agent_id` don't change the main session's state on their own.
