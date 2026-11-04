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

## Known gaps (to close before anything runs automations)

- The runner accepts XPC connections from any local process. Before M2 adds `run_snippet`,
  restrict it with `NSXPCConnection.setCodeSigningRequirement` to the main app's bundle id
  and team.
- A step that ignores cancellation can hold up its timeout (the engine waits for it to
  finish). Primitives are quick; M2's script steps run in child processes that are killed.
- Harness tests need the runner to come to the front. macOS 14+ only lets it if the main
  app yields activation first, which the Catalog's Run Tests button does.
