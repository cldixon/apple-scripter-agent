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

## M4 — Claude client and chat

Before you start: have an Anthropic API key ready, and remove any old one
(`security delete-generic-password -s dev.cldixon.AutomationAgent -a anthropic-api-key`).

- [ ] Launch: the window shows "Connect to Claude" instead of the sidebar.
- [ ] Paste a wrong key, press Validate and Continue: an error says the key was rejected; nothing is stored.
- [ ] Paste a valid key: the main window appears with Chat selected. Keychain Access lists
      "Automation Agent: Anthropic API key" (service `dev.cldixon.AutomationAgent`).
- [ ] `defaults read dev.cldixon.AutomationAgent` shows model/effort/cap settings but no key.
- [ ] Chat: send "Hello". The reply streams in, and the footer shows tokens and a cost below the cap.
- [ ] Send "What automations are installed?": a `list_automations` row appears (collapsed), expands to
      show the input `{}` and the runner's JSON; the reply summarises it. With the runner stopped, the
      row shows an error and Claude explains it.
- [ ] Send "Use the echo tool on 'abc' and 'def' at the same time": two echo rows, both succeed.
- [ ] Send a second message in the same conversation: the footer's cached-token count goes up
      (prompt caching works).
- [ ] Ask for something long, press Stop while it streams: the partial text is marked discarded,
      "Stopped." appears, and the next message works.
- [ ] Settings > Spend cap $0.01, then send messages until the footer passes $0.01: the next message
      stops at once with the spend-cap notice. New Conversation resets the footer to zero; raise the
      cap and a message works again.
- [ ] Settings > Model: Claude Sonnet 5.5, Effort: Low. Send a message: it works and costs less.
- [ ] Settings > Remove Key…: the window returns to onboarding and the Keychain item is gone.
