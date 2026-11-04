# Developing

## Requirements

- macOS 26 Tahoe or later, Xcode 26 or later
- [Homebrew](https://brew.sh), for `xcodegen` and `swiftlint`
- An Apple Developer team id for signing (a free personal team is enough for local builds)

## First build

```bash
make bootstrap
```

This installs the tools and creates `Config/Local.xcconfig`. Open it and set
`DEVELOPMENT_TEAM` to your team id (Xcode > Settings > Accounts shows it).

```bash
make run
```

This generates `AutomationAgent.xcodeproj` from `project.yml`, builds a signed Debug
app into `build/DerivedData`, checks the bundle layout and opens the app. To work in
Xcode instead, run `make project` and open the generated project; select the
`AutomationAgent` scheme.

`project.yml` is the source of truth for targets and settings. Never edit the
`.xcodeproj` by hand; change `project.yml` and run `make project` again.

## Why signing matters

macOS ties privacy permissions (Accessibility, Automation) and launch agent
registrations to the app's code signature. Both targets are signed with the same
team, and never ad hoc. If you change the team id or the app's location, unregister
the runner first (Runner screen > Unregister), then register again from the new build.

## Everyday commands

| Command | What it does |
| --- | --- |
| `make test` | Unit tests for the `Shared` package (`swift test`) |
| `make lint` | SwiftLint, warnings are errors |
| `make build-unsigned` | Build without signing, as CI does |
| `make verify` | Check the built app's bundle layout |
| `make clean` | Remove build output and the generated project |

## CI

`.github/workflows/ci.yml` runs on every pull request and on `main`: SwiftLint and
plist lint, the `Shared` unit tests, and an unsigned build of the whole app followed by
the bundle layout check. Anything that needs real permissions (launchd, XPC between
signed processes, Accessibility) cannot run in CI; it lives in
[integration-checklist.md](integration-checklist.md) and is checked by hand on a Mac.

## Troubleshooting

- **Runner shows "Needs approval".** Open System Settings > General > Login Items and
  allow "Automation Agent Runner" (the Runner screen has a button that opens it).
- **Ping fails with a connection error.** Check that the runner is registered and the
  gear icon is in the menu bar. `launchctl print gui/$(id -u)/dev.cldixon.AutomationAgent.Runner`
  shows launchd's view of it.
- **Two copies of the app.** launchd remembers the bundle path at registration. Unregister,
  delete stale builds, then register from the build you want to run.
- **Logs.** Both processes log under the `dev.cldixon.AutomationAgent` subsystem:
  `log stream --predicate 'subsystem == "dev.cldixon.AutomationAgent"'`.
