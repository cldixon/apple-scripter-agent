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
