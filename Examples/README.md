# Examples

Reference automations: one per backlog idea (issues #11–#20, label `automation-idea`) plus
the three early examples. Each folder is what the agent should produce: `manifest.json`,
`scripts/`, and `tests/fixtures/<name>/` when a script works on files.
`ExamplesTests` (Shared) decodes and validates every folder here on each CI run.

They use the Sweep 2 runtime: the `copySelection` and `askText` primitives, cancel as
skipped, default timeouts by step type, and `script` tests. Every applescript, jxa or shell
step that does not tell an app has script tests with fixed `inputs`; steps that tell an app
(Safari, Calendar, Finder, Reminders, System Events) cannot be script-tested, because
Apple Events are blocked in the test sandbox. CI only validates the manifests; the tests
themselves run on a Mac with the runner (Run Tests in the Catalog, or the agent's
`validate`).

| id | Issue | Approach | Tests | Still open |
| --- | --- | --- | --- | --- |
| `paste-plain-text` | #11 ⌃⌥⌘V | `readClipboard` → JXA `clean.js` (trim every line, drop blank lines) → `pasteText` (restores the clipboard's text) | unit: `readClipboard` with a fixed clipboard; script: 3 for `clean.js` | a harness test (the harness cannot set the clipboard) |
| `copy-safari-link` | #12 ⌃⌥⌘K (key chosen here) | JXA reads Safari's front tab without launching Safari → JXA `markdown-link.js` escapes `\ [ ]` in the title and `( )` and spaces in the URL → JXA copies only when there is a link → `notify` | script: 4 for `markdown-link.js` (plain, brackets, empty title, no page); 1 for `copy-if-any.js` with no link | step 0 (Safari) |
| `copy-finder-paths` | #13 ⌃⌥⌘C | AppleScript `selection as alias list` → POSIX paths, one per line → JXA copies only when something is selected → `notify` | script: `copy-if-any.js` with nothing selected | step 0 (Finder) |
| `quick-reminder` | #14 ⌃⌥⌘R (key chosen here) | `askText` (Cancel ends the run as skipped) → AppleScript trims the answer and adds it to list "Inbox" (created if missing) with `allday due date` today, 45 s timeout → `notify` | unit: `askText` answers its default ("") | step 1 (Reminders) |
| `today-events` | #15 manual | AppleScript reads one-off events with `whose` and every repeating series by bulk property reads → pure JXA `format-events.js` expands RRULEs (DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, excluded dates), lists all-day first, then remaining or in-progress events with `HH:mm` → `notify` | script: 3 for `format-events.js` (a busy Thursday, evening, no events; `now` comes from the input) | step 0 (Calendar) |
| `archive-downloads` | #16 manual, `destructive` | zsh: top-level regular files of `$HOME/Downloads` with mtime older than 30 days → `Archive/<yyyy-MM of mtime>/`; never overwrites (" 2", " 3" suffix, then `mv -n` and a check that the move happened); inputs `dryRun`, `folder`, `days` → inline shell takes the summary line → `notify` | script: dry run and real run on `tests/fixtures/downloads-case` (`days=0`, files checked with `expectFiles`/`expectMissing`); 2 for the summary step | — |
| `meeting-mode` | #17 ⌃⌥⌘M | `shortcut` step "Turn On Do Not Disturb" (the user creates it) → `openURL` | unit: the `openURL` step | — |
| `toggle-dark-mode` | #18 ⌃⌥⌘L | AppleScript: `set dark mode of appearance preferences to not dark mode` (System Events, no Accessibility) | none (the harness cannot see appearance; a script test cannot send Apple Events) | check with `run_snippet` reading `dark mode` |
| `window-left-half` | #19 ⌃⌥⌘← | JXA: System Events front window of the frontmost process (`AXMain` first); `NSScreen` frames converted from bottom-left to top-left coordinates; screen = largest overlap with the window; position, size, position | none | a pure geometry step with script tests, if it were split out |
| `title-case-selection` | #20 ⌃⌥⌘T | `copySelection` → pure JXA `title-case.js` → `pasteText` | script: 9 for `title-case.js`; harness: `setupText` selected with `"select": "all"`, expects the titled text | — |
| `insert-iso-date` | — | `formatDate` → `typeText` | unit + harness | — |
| `word-count-clipboard` | — | `readClipboard` → `wc -w` → `notify` | unit; script: 2 for the `wc -w` step | — |

## Fixtures

Text-in, text-out steps are tested with `inputs` and `expect` in the manifest, so they need
no fixture files. Only `archive-downloads` has a fixture folder:
`tests/fixtures/downloads-case/` holds `Downloads/` with two files, a subfolder and a hidden
file. A script test copies it to a temporary folder that becomes `HOME` and the working
directory, so the script's default `$HOME/Downloads` is the copy's `Downloads`; the fixtures
in this folder never change. Copied files are new, so the tests pass `days=0`. The archive
month comes from the copies' modification dates, so the tests check the summary with
`expectContains` and the moved files with `expectMissing` rather than naming
`Archive/<yyyy-MM>/` paths.

## Notes per example

- **#11** trims both ends of every line, so indentation is removed too; that is what "leading
  whitespace removed" most likely means for pasted prose, but not for code. `pasteText`
  restores only the clipboard's plain text: rich text that was on it comes back as plain.
- **#12, #13** write the clipboard from a script (`setTheClipboardTo`) only when there is
  something to copy, so an empty selection or a missing Safari window never clears it, and the
  notification says what happened. `writeClipboard` cannot be skipped conditionally. Their
  script tests cover only the nothing-to-copy branch, which does not touch the clipboard.
- **#14** `askText` shows the runner's own prompt in front, with a 300 s default timeout.
  Cancel ends the run as skipped (not failed), so step 1 never sees a cancel; an empty answer
  adds nothing and says so. `allday due date` gives a due date without a time; the script
  falls back to `due date` (midnight) if that property is refused.
- **#15** Calendar's `whose` sees only the first occurrence of a repeating event, so the
  repeating ones are read in bulk (`recurrence of every event`) and expanded in step 1. Rules it
  cannot expand are listed as "not checked" instead of guessed. Modified single occurrences
  of a repeating event are not handled specially (how Calendar exposes them is unverified).
  Large or subscribed calendars make step 0 slow: its timeout is 60 s.
- **#16** is `destructive`, so the install card asks twice and offers no Install Anyway. While
  exploring, run it with `AUTOMATION_VAR_dryRun=1` (or a temp `folder`). Age is the modification
  date, which for most downloads is when they were downloaded; "Date Added" (`mdls -name
  kMDItemDateAdded`) would be closer but slower. Folders and hidden files are not moved. The
  first real run triggers macOS's "access files in your Downloads folder" prompt for the runner.
- **#17** Focus has no AppleScript, JXA or shell API. Create the shortcut first: Shortcuts > New
  Shortcut, name it exactly "Turn On Do Not Disturb", add **Set Focus** → "Turn Do Not Disturb On
  until Turned Off". The agent should check `list_shortcuts` and ask the user to create it.
- **#19** Windows that are full screen, minimized or not resizable cannot be moved this way;
  the first returns a message, the others fail with the System Events error.
- **#20** `copySelection` waits for the hotkey's modifiers to be released, posts ⌘C and waits
  for the clipboard to change. With nothing selected the step fails with "Nothing is
  selected" and nothing is pasted. The copied selection stays on the clipboard afterwards.
