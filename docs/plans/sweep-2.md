# Sweep 2 plan

Goal: take v1 from "the date hotkey works" to "most everyday requests in the backlog
(issues #11–#20) work on the first try, are genuinely tested, and can be installed by
someone other than the developer". Everything lands on `main`; real-Mac testing follows.

## Why these workstreams

Reviewing the backlog against the code showed that most predicted failures come from
app gaps, not the agent:

| Gap | Blocks |
| --- | --- |
| Script steps cannot be tested (unit tests skip scripts; no fixtures) | #11 #12 #13 #15 #16 #18 #20 |
| No "copy selection" / "press keys" primitive; scripts send keystrokes while the hotkey's modifiers are held | #20 |
| User cancel (-128) counts as a failure toward Broken | #14 |
| 10 s default timeout is too short for slow or interactive steps | #14 #15 |
| Dialogs from the background runner can open behind other windows | #14 |
| Harness tests cannot start with text or a selection | #20 |
| The agent has thin reference material for these tasks | all |
| Only developers can install it (no signed, notarized build; permissions setup is scattered) | adoption |
| Automations are invisible to Shortcuts, Spotlight and Siri | adoption |

## Workstreams (parallel sub-agents, each in its own worktree and branch)

| # | Workstream | Branch | Owns |
| --- | --- | --- | --- |
| W1 | **Testable scripts**: `script` test kind that really runs a step's script in a sandbox (`sandbox-exec`: no network, no Apple Events, writes only to a temp folder) with fixed inputs and copied fixture files; harness tests that start with text and an optional selection | `s2-testing` | `ManifestTest.swift`, test part of `ManifestSchema`/`ManifestValidator`, `TestReport`, `RunnerCore+Testing`, `HarnessController`, new `ScriptTestRunner` |
| W2 | **Runtime primitives and robustness**: `copySelection`, `pressKeys`, `askText` primitives; user cancel → skipped (not failed); wait for modifier release before AppleScript/JXA; per-step-type default timeouts | `s2-runtime` | `Step.swift`, `AutomationEngine`, `AutomationEnvironment`, step part of `ManifestSchema`/`ManifestValidator`, `SystemActions`, `SystemEnvironment`, `ScriptRunner`, new `TextPrompt` |
| W3 | **Knowledge and evaluation**: reference implementations of every backlog idea in `Examples/`; new reference recipes (text transforms, windows/screens, Calendar, Reminders, appearance, Focus via Shortcuts, safe file moves, dialogs); a conversation-log report script and an evaluation guide | `s2-knowledge` | `Examples/`, `Reference/`, `scripts/conversation-report.py`, `docs/EVALUATING.md` |
| W4 | **Mac integration**: App Intents (each automation appears in Shortcuts, Spotlight and Siri: "Run … in Automation Agent"); a first-run Setup checklist (API key, runner, Accessibility, notifications) | `s2-macos` | new `App/Sources/Intents/`, new `SetupView`, small edits to `RootView`/`AutomationAgentApp` |
| W5 | **Release pipeline**: tag-triggered GitHub Actions workflow that builds Release, signs with Developer ID, notarizes, staples and publishes a DMG (skips cleanly when secrets are absent); `make release`; release docs | `s2-release` | `.github/workflows/release.yml`, `scripts/release.sh`, `docs/RELEASING.md`, Release signing settings |

The coordinator (main session) owns the system prompt (`AgentPrompt.swift`), README and
merges: each workstream reports the prompt guidance it needs, and the coordinator folds it
in once, so five agents never edit the prompt at once.

## Merge order

W2 → W1 → W3 → W4 → W5, one PR each, CI green before merge. W2 and W1 change the manifest
format, so they go first; W3's examples are then updated to use the new primitives and
test kinds where that makes them better.

## Done when

- CI green on `main` with every workstream merged.
- Each backlog issue has a reference example that validates in CI, with a real test.
- `docs/integration-checklist.md` has a "Sweep 2" section for on-Mac checks.
- The next real-Mac pass runs the backlog through chat and records success rate, cost and
  tool rounds per idea with `scripts/conversation-report.py`.
