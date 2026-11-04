# Mac Automation Agent (working name)

A native macOS app where you describe an automation in a chat box, and an embedded
Claude agent researches, writes, validates, installs and monitors it, keeping a
catalog of every automation it has made.

The design and build plan live in the "Mac Automation Agent — Overview & Handoff" doc.
This repo follows its milestones (M0–M6).

## Status

| Milestone | What | State |
| --- | --- | --- |
| M0 | Skeleton: app + background runner + XPC ping | Done |
| M1 | Runner core: manifests, primitives, hotkeys, harness | In progress |
| M2 | Script steps: AppleScript, JXA, shell, Shortcuts | Not started |
| M3 | Catalog | Not started |
| M4 | Claude client and chat | Not started |
| M5 | Agent tools and reference library | Not started |
| M6 | Monitoring | Not started |

## Quick start (macOS 26, Xcode 26)

```bash
make bootstrap   # installs xcodegen + swiftlint, creates Config/Local.xcconfig
# edit Config/Local.xcconfig and set DEVELOPMENT_TEAM
make run         # generates the Xcode project, builds, launches
```

See [docs/DEVELOPING.md](docs/DEVELOPING.md) for details and troubleshooting,
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit, and
[docs/integration-checklist.md](docs/integration-checklist.md) for the manual tests
to run on a real Mac.

## Layout

```
App/        SwiftUI main app: window, runner controller, (later) agent and chat
Runner/     Background runner: menu bar item, XPC listener, (later) triggers and executors
Shared/     Swift package used by both: identifiers, XPC protocol and messages
Config/     xcconfig build settings (Local.xcconfig holds your team id, git-ignored)
scripts/    Build helpers
Examples/   Sample automation folders (manifest.json + scripts)
docs/       Developer docs and the manual test checklist
project.yml XcodeGen spec; the .xcodeproj is generated, not committed
```
