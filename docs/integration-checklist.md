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
- [ ] Edit an installed manifest by hand to reference `{{missing}}`, choose Reload Automations from
      the gear menu: the Catalog shows it as not active with the validation error.
- [ ] Remove: the automation disappears and ⌃⌥⌘D no longer types anything.

## M2 — Script steps

- [ ] Catalog > Install Manifest… > `Examples/copy-finder-paths/manifest.json`: installs, status Active.
- [ ] Run Tests: "steps[0] compiles" passes.
- [ ] Select two files in Finder, press ⌃⌥⌘C. The first time, macOS asks whether
      **Automation Agent Runner** may control Finder (not Terminal or osascript). Allow it.
      The clipboard now holds both POSIX paths, one per line.
- [ ] Install `Examples/word-count-clipboard/manifest.json` (shell step), copy some text,
      choose Run Now: a notification shows the word count.
- [ ] Runner screen > Run Snippet (AppleScript): `tell application "Finder" to get name of every disk`
      returns your disk names.
- [ ] Snippet `delay 30` with timeout 3: it reports a timeout after about 3 seconds.
- [ ] Edit an installed script to have a syntax error, Reload Automations, Run Tests: the compile
      result fails with the compiler's message.
- [ ] In System Settings > Privacy & Security > Automation, turn off Finder for the runner and press
      ⌃⌥⌘C: the run fails with a message saying Automation permission is missing and where to allow it.
- [ ] Build a second copy of the app with a different bundle id (or use `nc`/another tool) and try to
      connect to the Mach service: the connection is refused.

## M3 — Catalog

Before you start: `xcode-select -p` prints a path (the command line tools provide `/usr/bin/git`).
Quit the runner from the gear menu so it starts fresh.

- [ ] Ping from the Runner screen. `~/Library/Application Support/AutomationAgent/` now has
      `automations/` (with `.git`), `drafts/` and `catalog.sqlite`. Automations installed
      before M3 are in the first commit (`git -C …/automations log` shows "Start version history").
- [ ] Catalog > Install Date Example: `git log` in `automations/` shows "Install insert-iso-date v1".
- [ ] Edit `Examples/insert-iso-date/manifest.json` to `"version": 2` and a new name, Install
      Manifest… with it: "Replace insert-iso-date v2". The Versions section lists v2 and v1, newest first.
- [ ] Show diff on v2: a sheet with the manifest diff in a monospaced font; text can be selected.
      Diff to latest on v1 shows the same change.
- [ ] Restore this version on v1: the name goes back, Versions shows "Roll back insert-iso-date to v1"
      on top, and ⌃⌥⌘D still types the date.
- [ ] Switch Enabled off: status Disabled, ⌃⌥⌘D types nothing, `state.json` lists the id and
      `git log` shows "Disable insert-iso-date". Switch it on: the hotkey works again.
- [ ] Search for "date" and for "zzz"; filter by Disabled and by Active: the list follows.
- [ ] Run the automation, then `sqlite3 catalog.sqlite 'select automation_id, outcome from runs'`
      lists the run; `select id, status, current_version from automations` matches the Catalog.
- [ ] Quit the runner, delete `catalog.sqlite` (or overwrite it with junk), Ping: the index is
      rebuilt, with the automations and every run from `runs.jsonl`.
- [ ] Remove: "Remove insert-iso-date" is committed and the folder is gone.
- [ ] Without git (temporarily rename the command line tools, or test on a Mac without them):
      the runner starts, installs still work, the gear menu says "Version history is off", and the
      Versions section explains why.

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

## M5 — Runner side (reference library, drafts)

Before you start: quit the runner from the gear menu so it starts fresh. Most checks use the
agent's tools from Chat; `sqlite3` and the Finder are enough for the rest.

- [ ] Ping, then open the gear menu: a "Reference library: building…" line appears, and within
      a minute or two changes to "Reference library: N chunks, built HH:MM" (N in the thousands).
- [ ] `~/Library/Application Support/AutomationAgent/reference/library.sqlite` exists;
      `sqlite3 … 'select origin from origins'` lists `bundled:recipes.md`, `man:pmset`,
      `sdef:com.apple.finder`, `sdef:com.apple.systemevents` and the installed automations.
- [ ] `Contents/Library/LoginItems/AutomationAgentRunner.app/Contents/Resources/Reference/` in the built app holds the
      six markdown files.
- [ ] Quit and relaunch the runner: the second build finishes in seconds (unchanged sources are skipped).
- [ ] Ask the agent "How do I split text by commas in AppleScript?": it searches the reference and
      reads `recipes/text-item-delimiters` (or similar) before answering.
- [ ] search_reference with `"unbalanced quote AND (` returns results or an empty list, never an error.
- [ ] introspect_app "Finder" with query "window" returns classes and commands about windows;
      "Mail" without a query returns a truncated summary; "Calculator" says it is not scriptable.
- [ ] list_apps lists Finder, Safari and Mail with bundle ids; running apps are marked running.
- [ ] list_shortcuts returns the names in the Shortcuts app.
- [ ] check_permissions for accessibility, automation:com.apple.finder, fullDiskAccess and
      screenRecording matches System Settings > Privacy & Security; with Mail quit,
      automation:com.apple.mail says "launch the app to check".
- [ ] read_automation insert-iso-date returns the manifest and no binary files.
- [ ] write_draft with a manifest that has `"trigger": 5` fails with a message naming `trigger`.
- [ ] write_draft with a file path `../x.sh` fails and writes nothing under `drafts/`.
- [ ] write_draft of a valid automation creates `drafts/<id>/`; writing it again with fewer files
      replaces the folder (old files are gone).
- [ ] validate_draft runs compile, unit and harness tests (the harness window appears for a harness
      test; the hotkey is not posted); `runs.jsonl` has a `test` run with the draft's id.
- [ ] install_draft installs it (Catalog shows it, `git log` has "Install <id> v1", the hotkey works)
      and `drafts/<id>/` is gone. discard_draft on another draft deletes its folder.
- [ ] Update an app (or change a scriptable app's version), wait for the six-hourly rebuild or relaunch
      the runner: only that app's `sdef:` origin changes (`select origin, updated from origins`).

## M5 — End to end

Before you start: the runner is running, the API key is set, and the catalog has no
automation on ⌃⌥⌘D (remove `insert-iso-date` if it is installed).

- [ ] Chat: "When I press ⌃⌥⌘D, type today's date as yyyy-MM-dd at the cursor". Claude checks the
      catalog (`search_catalog`), writes a draft, validates it (unit test for the date step,
      harness test for the typed text) and fixes it until it passes, with no code edits.
- [ ] The install card shows the name, trigger "Hotkey ⌃⌥⌘D", each step with its fields, the
      `accessibility` permission, "Validation: passed" and every test. Approve and Install.
- [ ] A "Please test" card asks you to press ⌃⌥⌘D in a text field. Do it: today's date is typed.
      Answer Works. The Catalog lists the automation as Active, version 1.
- [ ] Chat: "a hotkey that copies the paths of my selected Finder items". Claude reads Finder's
      dictionary (`introspect_app`) before writing AppleScript, may ask to run a snippet (approve
      once; try "Run and Trust This Conversation" on the next one and confirm later snippets run
      without a card), and declares `automation:com.apple.finder`.
- [ ] Approve the install, select two files in Finder, press the hotkey: their POSIX paths are on
      the clipboard. Answer Works. The automation is Active in the Catalog.
- [ ] Answer "Didn't work" with a note on a test card: Claude reads the run log (`read_run_log`),
      fixes the draft, validates and asks to install again.
- [ ] Decline an install card with a reason: Claude reports the reason and nothing is installed.
- [ ] A draft with `"destructive": true`: the card says so in red, and Approve asks a second time.
- [ ] While a card waits, press Stop: the card shows "Cancelled", the tool row shows an error,
      "Stopped." appears and the next message works. New Conversation clears cards and trust.
- [ ] Ask Claude to disable the date automation: a card asks first; after Approve the Catalog shows
      Disabled. Ask it to enable it again.
- [ ] Ask Claude to fetch an ss64.com page: the result starts with the untrusted-content line.
      Ask it to fetch https://example.com: the tool refuses the host.

## M6 — Monitoring

- [ ] Install the date example and run it once from the Catalog: Health says "No recent failures."
- [ ] In System Settings > Privacy & Security > Accessibility, turn the runner off. Press ⌃⌥⌘D in
      TextEdit three times. After the third, a notification says the automation is broken, the
      runner menu lists it under "Broken", and the Catalog shows status Broken with the last error.
- [ ] Turn Accessibility back on and press ⌃⌥⌘D: it types the date, and after a Catalog refresh the
      status is Active again with no failures.
- [ ] Break a script by hand: edit `copy-finder-paths/scripts/selected-paths.applescript` in the
      automations folder to call a misspelled Finder property, choose Reload Automations, and press
      ⌃⌥⌘C three times with files selected: it becomes Broken.
- [ ] Catalog > that automation > Fix with Agent: Chat opens with a message naming the automation
      and its errors; the agent reads it, proposes a corrected draft at the next version, validates
      it and asks you to approve. After approval the failure count is cleared and ⌃⌥⌘C works.

## Sweep 2 — Examples and evaluation

Install each example with Catalog > Install Manifest… (`Examples/<id>/manifest.json`), remove
any automation already on the same hotkey, and run Run Tests first: every script must compile.

- [ ] `paste-plain-text`: copy text with indentation, trailing spaces and blank lines from a web
      page; press ⌃⌥⌘V in TextEdit: trimmed lines, no blank lines, no formatting. The clipboard
      still holds the original text afterwards.
- [ ] `copy-safari-link`: with a Safari page whose title contains `[brackets]`, press ⌃⌥⌘K: the
      clipboard holds `[\[brackets\] …](url)` and a notification says so. Quit Safari and press it
      again: the notification says nothing was copied, Safari does not launch, the clipboard is
      unchanged.
- [ ] `copy-finder-paths`: select two files (one with a space or an accent in its name) and press
      ⌃⌥⌘C: both paths, one per line, and a "Copied 2 paths" notification. Click the desktop with
      nothing selected and press it again: "Nothing is selected", clipboard unchanged.
- [ ] `quick-reminder`: press ⌃⌥⌘R in another app: the dialog appears in front. Type a line, Add:
      a reminder due today in "Inbox" (rename your Inbox first to see it created). Press it again
      and Cancel: nothing is added and the run is not counted as a failure.
- [ ] `today-events`: with a one-off event later today, a repeating weekly event that started weeks
      ago, an all-day event, and an event that already ended, choose Run Now: the notification lists
      the all-day event first, then the remaining ones with start times, not the ended one. Check
      the step's duration in Recent runs (timeout 60 s).
- [ ] `archive-downloads`: in Terminal, `AUTOMATION_VAR_dryRun=1 zsh
      Examples/archive-downloads/scripts/archive-downloads.sh` prints the plan and moves nothing.
      Install (the card asks twice: destructive), Run Now: macOS asks for Downloads access for the
      runner; files older than 30 days are in `Archive/<year-month>/`, existing names get " 2".
- [ ] `meeting-mode`: without the "Turn On Do Not Disturb" shortcut, ⌃⌥⌘M fails with a clear
      "shortcut not found" error. Create it (Set Focus → Do Not Disturb On until turned off): ⌃⌥⌘M
      turns on Do Not Disturb and opens the Zoom link.
- [ ] `toggle-dark-mode`: ⌃⌥⌘L switches Light ↔ Dark; the first run asks to control System Events.
- [ ] `window-left-half`: ⌃⌥⌘← on a Safari window fills the left half below the menu bar. With a
      second display, move the window there first: it snaps to that display's left half. Try a
      display arranged above or left of the main one (negative coordinates).
- [ ] `title-case-selection`: in TextEdit select "the lord of the rings: the return of the king"
      and press ⌃⌥⌘T, releasing the keys slowly: the selection becomes "The Lord of the Rings: The
      Return of the King" and the clipboard keeps its earlier text. With nothing selected nothing
      changes.
- [ ] Run one backlog idea through chat as in `docs/EVALUATING.md`, then
      `scripts/conversation-report.py` on its log: the row shows the request, model, tool calls,
      approvals, the installed id, the test answer and a cost close to the chat's.
