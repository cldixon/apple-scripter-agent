# Integration checklist

Manual checks on a real Mac for things CI cannot exercise (launchd, signed XPC,
permission prompts). Run the section for the milestone you are verifying, from a
clean state: Runner screen > Unregister, quit the runner, then `make run`.

## M0 — Skeleton

- [ ] `make run` builds and opens a window with Chat, Catalog, Runner and Settings in the sidebar.
- [ ] The Runner screen shows "Launch agent: Enabled" (or "Needs approval": approve it in
      Login Items, then press Refresh).
- [ ] A gear icon appears in the menu bar; its menu shows the runner's start time and process id.
- [ ] Ping Runner succeeds and shows a round trip, the runner's process id and version.
- [ ] The sidebar footer reads "Runner connected".
- [ ] Quit the main app. The runner's gear icon stays in the menu bar.
- [ ] Reopen the app. Ping succeeds against the same runner process id, and "Pings served" has gone up.
- [ ] Choose Quit Runner from the gear menu, then Ping from the app: launchd relaunches the
      runner on demand and the ping succeeds with a new process id.
- [ ] Unregister: the gear icon disappears and Ping fails with a connection error. Register brings it back.
- [ ] Log out and back in: the runner starts by itself.

## M1 — Runner core

Before you start: the runner needs Accessibility to type. On the Runner screen, Ping, then
use "Allow…" next to Accessibility (or the gear menu's "Allow Accessibility…"), and switch
on "AutomationAgentRunner" in System Settings > Privacy & Security > Accessibility.

- [ ] Catalog > Install Date Example: "Insert today's date" appears, status Active, trigger ⌃⌥⌘D.
- [ ] Run Tests: the harness window appears briefly; all results pass, including the
      "(hotkey ⌃⌥⌘D)" one.
- [ ] Open TextEdit, place the cursor in a document, press ⌃⌥⌘D: today's date is typed as yyyy-MM-dd.
- [ ] Same in Notes.
- [ ] Recent runs on the Catalog screen lists those hotkey runs as succeeded.
- [ ] Pause All (toolbar or gear menu), press ⌃⌥⌘D in TextEdit: nothing is typed. Unpause: it works again.
- [ ] Quit the main app, press ⌃⌥⌘D in TextEdit: it still works (the runner owns the hotkey).
- [ ] Install Manifest… with `Examples/copy-finder-paths/manifest.json`: it is refused with an
      error that applescript steps are not supported yet (they arrive in M2).
- [ ] Edit an installed manifest by hand to reference `{{missing}}`, choose Reload Automations from
      the gear menu: the Catalog shows it as not active with the validation error.
- [ ] Remove: the automation disappears and ⌃⌥⌘D no longer types anything.
