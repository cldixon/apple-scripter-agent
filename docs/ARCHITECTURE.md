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

## Known gaps (to close before anything runs automations)

- The runner accepts XPC connections from any local process. Before M2 adds `run_snippet`,
  restrict it with `NSXPCConnection.setCodeSigningRequirement` to the main app's bundle id
  and team.
- A step that ignores cancellation can hold up its timeout (the engine waits for it to
  finish). Primitives are quick; M2's script steps run in child processes that are killed.
- Harness tests need the runner to come to the front. macOS 14+ only lets it if the main
  app yields activation first, which the Catalog's Run Tests button does.
