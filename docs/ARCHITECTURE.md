# Architecture

Two signed processes share one catalog. The main app talks to Claude and drafts
automations; the runner, a background process that holds every permission, executes them.
M0 builds the two processes and the connection between them.

```
┌──────────────────────────┐   XPC (Mach service)   ┌──────────────────────────┐
│ AutomationAgent.app      │ ─────────────────────▶ │ AutomationAgentRunner.app │
│ SwiftUI window           │   ping (M0)            │ menu bar item, no Dock    │
│ RunnerController         │   load / test / run    │ NSXPCListener             │
│ (later) agent + chat     │   (M1+)                │ (later) triggers, steps   │
└──────────────────────────┘                        └──────────────────────────┘
          │ SMAppService.agent(plistName:)                       ▲
          ▼                                                      │ starts at login,
       launchd ──────────────────────────────────────────────────┘ restarts on crash
```

## Bundle layout

```
AutomationAgent.app/Contents/
  MacOS/AutomationAgent
  Library/LaunchAgents/dev.cldixon.AutomationAgent.Runner.plist
  Library/LoginItems/AutomationAgentRunner.app
```

The launch agent plist points `BundleProgram` at the embedded runner and declares the
Mach service `dev.cldixon.AutomationAgent.Runner.xpc`. `RunAtLoad` starts the runner at
login; `KeepAlive.SuccessfulExit = false` restarts it after a crash but not after
"Quit Runner". launchd also starts it on demand when the app looks up the Mach service.

## Names that must match

Bundle ids, the launch agent label, the plist file name and the Mach service name all
live in `Shared/Sources/Shared/Identifiers.swift`. The same strings appear in
`project.yml` and the plists; `IdentifiersTests` fails if they drift apart.

## XPC messages

`RunnerXPCProtocol` has one method per request. Each takes and returns JSON-encoded
`Codable` structs (`RunnerMessages.swift`) as `Data`, so new fields are plain Swift and
the Objective-C surface stays tiny. The client opens a connection per call and resolves
on the first of: reply, connection error, or a 3 second timeout (`ResumeOnce`).

## Automations (M1)

An automation is a folder with a `manifest.json` (see `ManifestSchema.swift` and
`Examples/`). The runner keeps installed automations in
`~/Library/Application Support/AutomationAgent/automations/<id>/` and appends one JSON
line per run to `runs.jsonl` beside it.

```
manifest.json ──decode──▶ AutomationManifest ──validate──▶ [ValidationIssue]
                                │
            trigger (hotkey) ───┤ HotkeyCenter (Carbon RegisterEventHotKey, no permission)
                                ▼
                          AutomationEngine ── steps in order, {{name}} outputs, per-step timeout
                                │
                    AutomationEnvironment ── SystemEnvironment (runner: CGEvent typing, pasteboard,
                                             NSWorkspace) or RecordingEnvironment (unit tests)
```

- **Shared** holds everything that can be tested without a Mac's permissions: manifest
  types, templating, validation, the engine, the store and unit-test runner.
- **Runner** supplies the real environment, hotkeys and the harness window: a small
  window the runner owns, which automations type into during harness tests. A harness test
  runs the automation directly, then posts its real hotkey, and compares the window's text.
- **App** sends `RunnerCommand`s (list, install, run, test, remove, pause) and shows the
  replies on the Catalog screen. It never runs automations itself.

Only `primitive` steps run in M1; the validator rejects other step types until M2.

## Script steps (M2)

`applescript`, `jxa`, `shell` and `shortcut` steps run as child processes of the runner
(`osascript`, `zsh`, `shortcuts run`), so a step that overruns its timeout is killed
(SIGTERM, then SIGKILL). Because the runner launches them, macOS attributes their Apple
Events to the runner: the Automation prompt names "Automation Agent Runner".

Input/output contract: a script receives every named output so far as one JSON object:

| Language | Where the JSON arrives |
| --- | --- |
| AppleScript | first item of `on run argv` |
| JXA | `run(argv)` → `argv[0]` |
| shell | `$AUTOMATION_INPUT`, plus `$AUTOMATION_VAR_<name>` per value |
| shortcut | the step's `input` string (templated) as the shortcut's input |

Whatever the script returns or prints is the step's output (one trailing newline removed).

Checks before a script runs:
- **Install and Run Tests** compile AppleScript/JXA (`osacompile`) and syntax-check shell
  (`zsh -n`); a script that does not compile is not installed.
- **Declared permissions**: the validator reads `tell application "…"` / `Application("…")`
  and requires `automation:<bundle id>` permissions; at run time the runner resolves each
  app name to its bundle id and refuses a script that targets an undeclared app.
- Error -1743 (Automation denied) is reported as a permission problem with where to fix it.

`run_snippet` (`RunnerCommand.runSnippet`) runs a short script for exploration and returns
stdout, stderr, exit code and duration. The main app asks the user first; the Runner screen
has a small debug form for it.

## Who may connect

The runner's XPC listener requires clients to be signed as `dev.cldixon.AutomationAgent` by
the same Apple Developer team as the runner itself (`CodeSigning.clientRequirement()`).
A build without a team falls back to checking the bundle id only.

## Catalog (M3)

The catalog is a git repository of automation folders plus a SQLite index. The folders
are the source of truth; the index can always be rebuilt from them.

```
~/Library/Application Support/AutomationAgent/
  automations/            git repository, one commit per approved change
    .git/  .gitignore
    state.json            {"disabled": [ids]}: versioned with everything else
    <id>/manifest.json    (+ scripts/, tests/fixtures/)
  drafts/                 the agent's working area (M5), not versioned
  catalog.sqlite          the index: automations, runs, tests, conversations
  runs.jsonl              the durable run log (unchanged from M1)
```

- **CatalogRepository** (Shared) wraps `AutomationStore` and `/usr/bin/git` (`GitClient`,
  run through `Process`). `prepare()` creates the folders, runs `git init` once, sets a
  local identity ("Automation Agent" <runner@localhost>), turns off commit signing and
  global hooks, and commits anything uncommitted. Install, replace, remove, enable,
  disable and rollback each make one commit ("Install insert-iso-date v1",
  "Replace … v2", "Remove …", "Disable …", "Roll back … to v1"). If git is missing or
  fails, `versioningError` says why, changes are still saved, and only history, diff
  and rollback refuse; the runner's menu and the Catalog's Versions section show it.
- **History** is `git log -- <id>`; each entry's version number is read from the
  manifest at that commit (none for a removal). **Diff** is `git show` (against the
  parent) or `git diff` between two commits, limited to the folder. **Rollback**
  replaces the folder with its contents at that commit (`git checkout <hash> -- <id>`),
  commits, and the runner reloads. Commit hashes and ids are checked before they reach
  git, so neither can be read as an option.
- **CatalogIndex** (Shared, system `SQLite3`) has the tables `automations` (id, name,
  description, request, trigger summary, status, current version, created, updated),
  `runs` (one row per run with an output excerpt), `tests` (the last report per
  automation version, as JSON) and `conversations` (automation id, conversation id,
  created; written from M4/M5). The runner opens it at start; if it is missing or fails
  `PRAGMA quick_check` or has an unknown schema version, it is recreated and rebuilt from
  the folders and `runs.jsonl` (`rebuild(from:)`, also the `rebuildIndex` command).
  Each reload syncs the automations table; runs and test reports are added as they happen.
- **Status** (`AutomationStatus`): draft, validating, awaiting_approval, active, disabled,
  broken. The runner computes disabled (from `state.json`), broken (validation errors or
  a trigger that could not be registered) and active. Disabling unregisters the trigger
  and keeps the folder. The other three belong to the agent's drafting flow.
- **Commands**: `setEnabled`, `history`, `diff`, `rollback` and `rebuildIndex`, answered by
  `enabledChanged`, `history`, `diff`, `rolledBack` (or `failure`). Git runs synchronously
  on the runner's main actor; catalog operations are small and rare.

## Claude client and chat (M4)

The main app talks to the Claude Messages API over raw HTTP (there is no Swift SDK). Logic
that can be tested without a network lives in the `AgentCore` library in the `Shared`
package; the app supplies the URLSession transport, the Keychain and the views.

```
ChatView ─▶ ChatController ─▶ AgentRunner ─▶ MessagesTransport ─▶ POST /v1/messages (SSE)
 (SwiftUI)   (@MainActor)      (AgentCore)     URLSessionTransport      │
                                  │                                     ▼
                                  │       LineBuffer ▶ SSEParser ▶ StreamEvent ▶ MessageAccumulator
                                  ▼
                            ToolRegistry ─▶ AgentTool (list_automations ▶ RunnerClient, echo)
```

- **API key.** On first launch (and whenever no key is stored) the window shows onboarding.
  A key is checked with `GET /v1/models` (free), then stored as a generic password in the
  login Keychain (service `dev.cldixon.AutomationAgent`, account `anthropic-api-key`). It
  only ever goes into the `x-api-key` header. Settings can replace it (validated again) or
  remove it, which returns the window to onboarding.
- **Settings** (UserDefaults): model (`claude-opus-5-5` default, or `claude-sonnet-5-5`),
  effort (`high` default; sent explicitly because the Opus 5.5 default is `medium`), spend
  cap per conversation ($2.00 default), tool rounds per message (40), server-side fallback (on).
- **Requests.** `anthropic-version: 2026-10-21`, so no `temperature`/`top_p`/`top_k`.
  `stream: true`, `max_tokens: 64000` (thinking counts toward it), `thinking: adaptive`
  (thinking cannot be turned off on these models), `output_config.effort`, no `tool_choice`
  (forced choices are rejected), no assistant prefill. `fallbacks: "default"` with the
  `server-side-fallback-2026-07-01` beta re-runs a request a safety classifier declines.
  Tools carry `eager_input_streaming: true`; their input is parsed strictly and checked
  against the tool's schema before a tool runs, and bad input goes back as an `is_error`
  result.
- **Caching.** Breakpoints on the last tool definition and on the system prompt, plus the
  top-level automatic breakpoint that follows the end of the conversation. The system prompt
  and tool list are fixed strings (no dates or settings) and are serialized with sorted keys.
- **Conversation.** Append-only. Assistant content is stored as the raw JSON of each block
  and sent back unchanged, so thinking, redacted thinking and unknown block types survive
  (preserved thinking needs the history byte-identical). The one exception the API asks for:
  after a mid-output fallback, the declined model's thinking and tool calls before the last
  `fallback` block are dropped when the response is stored.
- **Loop.** Stream a response; on `tool_use` run every requested tool and send all results in
  one user message; on `pause_turn` send the conversation back; stop on `end_turn`,
  `max_tokens`, `refusal` (checked before any tool runs; the partial output is discarded and
  not stored), the user's Stop (task cancellation), the spend cap, or the tool-round cap. A
  tool call that will not run still gets an error result, so the next request is valid.
- **Cost.** Usage comes from `message_start` and `message_delta`. Estimates use $4/$20 per
  million input/output tokens for Opus 5.5 and $2/$10 for Sonnet 5.5, $0.20 for cache reads
  and 1.25x input for cache writes. A response served by another model (a fallback) is priced
  as Opus 5.5 unless it is Sonnet 5.5, so the estimate errs high.

Conversations live in memory only. Thinking is not displayed (its text is omitted by
default), so the transcript can be quiet between tool calls; the system prompt asks for a
one-line note before each tool call.

## Agent tools: app side (M5)

The tools live in the main app (`App/Sources/AgentTools*.swift`); each is a Sendable
`AgentTool` that sends one `RunnerCommand` through `RunnerClient` and turns the reply into
short JSON or markdown for Claude. Pure helpers (input parsing, HTML to text, the fetch
allowlist, text search, the assembled system prompt) are in AgentCore and tested there.

| Tool | Runner command | Asks the user |
|---|---|---|
| `search_reference`, `read_reference` | `searchReference`, `readReference` | no |
| `introspect_app` | `introspectApp` | no |
| `list_apps`, `list_shortcuts` | `listApps`, `listShortcuts` | no |
| `check_permissions` | `checkPermissions` | no |
| `fetch_url` | none: app-side `URLSession` GET | no |
| `search_catalog` | `listAutomations`, filtered by id/name/description in the app | no |
| `read_automation` | `readAutomation` | no |
| `read_run_log` | `recentRuns(limit: 200)`, filtered by automation id | no |
| `run_snippet` | `runSnippet` | each call, unless "Trust this conversation" was chosen |
| `set_status` | `setEnabled` or `rollback` | each call |
| `write_draft` | `writeDraft` | no |
| `validate` | `validateDraft` | no |
| `request_install` | `installDraft` after approval | always (the install card) |
| `ask_user` | none | it is the question |

`list_automations` and `echo` are no longer offered (`search_catalog` with no query lists
everything; `EchoTool` stays in AgentCore for its tests).

- **Cards.** `InteractionCenter` (`@MainActor @Observable`, owned by `ChatController`) holds
  approval and question cards. A tool calls `await center.ask(request)`, which posts a card
  (the chat appends a `.card` row to the transcript) and suspends on a continuation until the
  user answers. Stop and New Conversation resume every waiting card with `.cancelled`, and
  the tool returns an error result, so the loop can end; task cancellation does the same.
  "Trust this conversation" on a snippet card skips later snippet approvals until New
  Conversation.
- **Drafts.** `DraftStore` (memory only, cleared by New Conversation) keeps the manifest JSON
  and files of each draft `write_draft` sent, and the last `validate` report. A rewrite clears
  the report. `request_install` refuses a draft that was not written in this conversation, has
  no report since it was last written, or failed; otherwise it shows the install card: name,
  id, trigger, each step with its key fields and its script in full, other files, declared
  permissions, `destructive` in red (Approve then asks a second time) and the validation
  report. Approve is disabled without a passing report. After approval it sends
  `installDraft` and refreshes the Catalog.
- **fetch_url** accepts only https on developer.apple.com, support.apple.com,
  macosxautomation.com, www.macosxautomation.com and ss64.com, refuses redirects that leave
  the list, strips HTML to text (scripts, styles and comments dropped, whitespace collapsed),
  caps it at 20,000 characters and prefixes a line marking it untrusted.
- **System prompt.** `AgentPrompt.system` (AgentCore) plus `ManifestSchema.json` (Shared),
  joined in the app by `AgentPrompt.assembled(manifestSchema:)`. It is fixed text so it caches:
  role, layer routing (primitive, shell, Shortcuts, Apple Events, then UI scripting through
  System Events), the step input/output contract, tests, permissions and `destructive`, the
  workflow (catalog, research, write, validate, install, test, fix), and treating fetched or
  tool output as data.

## Known gaps

- Harness tests need the runner to come to the front. macOS 14+ only lets it if the main
  app yields activation first, which the Catalog's Run Tests button does.
