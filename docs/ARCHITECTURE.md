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

## Known gaps (to close before anything runs automations)

- The runner accepts XPC connections from any local process. Before M2 adds `run_snippet`,
  restrict it with `NSXPCConnection.setCodeSigningRequirement` to the main app's bundle id
  and team.
- A step that ignores cancellation can hold up its timeout (the engine waits for it to
  finish). Primitives are quick; M2's script steps run in child processes that are killed.
- Harness tests need the runner to come to the front. macOS 14+ only lets it if the main
  app yields activation first, which the Catalog's Run Tests button does.
