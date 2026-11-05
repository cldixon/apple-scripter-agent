# Examples

Reference automations: one per backlog idea (issues #11–#20, label `automation-idea`) plus
the three early examples. Each folder is what the agent should produce: `manifest.json`,
`scripts/`, and `tests/fixtures/` where a script can be tested with fixed inputs.
`ExamplesTests` (Shared) decodes and validates every folder here on each CI run.

They use only what the runner supports today: `primitive`, `applescript`, `jxa`, `shell` and
`shortcut` steps, and `unit` and `harness` tests. Unit tests run script steps in a recording
environment that returns an empty output, so today most of these have no meaningful
declared test; their logic is split into pure script steps with fixtures, ready for a
script test.

| id | Issue | Approach | Test today | Would improve with |
| --- | --- | --- | --- | --- |
| `paste-plain-text` | #11 ⌃⌥⌘V | `readClipboard` → JXA `clean.js` (trim every line, drop blank lines) → `pasteText` (restores the clipboard's text) | unit: `readClipboard` with a fixed clipboard; fixture `messy` for `clean.js` | script test for step 1 |
| `copy-safari-link` | #12 ⌃⌥⌘K (key chosen here) | JXA reads Safari's front tab without launching Safari → JXA `markdown-link.js` escapes `\ [ ]` in the title and `( )` and spaces in the URL → JXA copies only when there is a link → `notify` | none; fixtures `brackets`, `empty-title`, `no-page` for step 1 | script test for step 1 |
| `copy-finder-paths` | #13 ⌃⌥⌘C | AppleScript `selection as alias list` → POSIX paths, one per line → JXA copies only when something is selected → `notify` | none | script test for step 1 (pasteboard access in the sandbox permitting) |
| `quick-reminder` | #14 ⌃⌥⌘R (key chosen here) | AppleScript `display dialog` shown by System Events after `activate`, Cancel (-128) caught and returned as "" → AppleScript adds to list "Inbox" (created if missing) with `allday due date` today → `notify` | none | **askText** (replaces step 0 and the System Events permission); cancel → skipped |
| `today-events` | #15 manual | AppleScript reads one-off events with `whose` and every repeating series by bulk property reads → pure JXA `format-events.js` expands RRULEs (DAILY/WEEKLY/MONTHLY/YEARLY, INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH, excluded dates), lists all-day first, then remaining or in-progress events with `HH:mm` → `notify` | none; fixtures `thursday`, `evening` for step 1 (`now` comes from the input) | script test for step 1 |
| `archive-downloads` | #16 manual, `destructive` | zsh: top-level regular files with mtime older than 30 days → `Archive/<yyyy-MM of mtime>/`; never overwrites (" 2", " 3" suffix, then `mv -n` and a check that the move happened); inputs `dryRun`, `folder`, `days` → inline shell takes the summary line → `notify` | none; fixture folder `downloads/` | script test with `dryRun=1`, `days=0`, `folder` = the copied fixtures |
| `meeting-mode` | #17 ⌃⌥⌘M | `shortcut` step "Turn On Do Not Disturb" (the user creates it) → `openURL` | unit: the `openURL` step | — |
| `toggle-dark-mode` | #18 ⌃⌥⌘L | AppleScript: `set dark mode of appearance preferences to not dark mode` (System Events, no Accessibility) | none (the harness cannot see appearance) | a script test cannot help (it needs Apple Events); check with `run_snippet` reading `dark mode` |
| `window-left-half` | #19 ⌃⌥⌘← | JXA: System Events front window of the frontmost process (`AXMain` first); `NSScreen` frames converted from bottom-left to top-left coordinates; screen = largest overlap with the window; position, size, position | none | a pure geometry step with fixtures, if it were split out |
| `title-case-selection` | #20 ⌃⌥⌘T | JXA: wait for modifiers to be released, ⌘C via System Events, wait for the clipboard's change count, restore its text → pure JXA `title-case.js` → `pasteText` | none; 9 fixtures for step 1 | **copySelection** (replaces step 0); harness test that starts with selected text; script test for step 1 |
| `insert-iso-date` | — | `formatDate` → `typeText` | unit + harness | — |
| `word-count-clipboard` | — | `readClipboard` → `wc -w` → `notify` | unit | script test for step 1 |

## Fixtures

`tests/fixtures/<case>/input.json` is the JSON object a script step receives (every named
output so far), and `expected.txt` is its expected output (one trailing newline ignored,
as the runner removes one). Each case belongs to the step named in the table. For
`archive-downloads`, `tests/fixtures/downloads/` is a folder to copy and pass as `folder`;
with `dryRun=1` and `days=0` the first output line is
`Dry run: would move 2 file(s) older than 0 days into Archive.` (the next lines name the
current month, so compare only the first line).

## Notes per example

- **#11** trims both ends of every line, so indentation is removed too; that is what "leading
  whitespace removed" most likely means for pasted prose, but not for code. `pasteText`
  restores only the clipboard's plain text: rich text that was on it comes back as plain.
- **#12, #13** write the clipboard from a script (`setTheClipboardTo`) only when there is
  something to copy, so an empty selection or a missing Safari window never clears it, and the
  notification says what happened. `writeClipboard` cannot be skipped conditionally.
- **#14** uses System Events to show the dialog because a dialog from the background runner may
  open behind other windows. It returns "" on Cancel or after 100 seconds, so a cancel is not a
  failed run today. `allday due date` gives a due date without a time; the script falls back to
  `due date` (midnight) if that property is refused.
- **#15** Calendar's `whose` sees only the first occurrence of a repeating event, so the
  repeating ones are read in bulk (`recurrence of every event`) and expanded in step 1. Rules it
  cannot expand are listed as "not checked" instead of guessed. Modified single occurrences
  of a repeating event are not handled specially (how Calendar exposes them is unverified).
  Large or subscribed calendars make step 0 slow: its timeout is 60 s.
- **#16** is `destructive`, so the install card asks twice and offers no Install Anyway. While
  exploring, run it with `AUTOMATION_VAR_dryRun=1` (or a temp `folder`). Age is the modification
  date, which for most downloads is when they were downloaded; "Date Added" (`mdls -name
  kMDItemDateAdded`) would be closer but slower. Folders are not moved. The first real run
  triggers macOS's "access files in your Downloads folder" prompt for the runner.
- **#17** Focus has no AppleScript, JXA or shell API. Create the shortcut first: Shortcuts > New
  Shortcut, name it exactly "Turn On Do Not Disturb", add **Set Focus** → "Turn Do Not Disturb On
  until Turned Off". The agent should check `list_shortcuts` and ask the user to create it.
- **#19** Windows that are full screen, minimized or not resizable cannot be moved this way;
  the first returns a message, the others fail with the System Events error.
- **#20** needs a **copySelection** primitive to be reliable. A hotkey fires while ⌃⌥⌘ are still
  held, so a ⌘C posted at once arrives as ⌃⌥⌘C (here, the `copy-finder-paths` hotkey). The
  script waits until `NSEvent.modifierFlags` shows no modifier (at most 1.5 s), then posts ⌘C
  and polls `NSPasteboard.changeCount` (at most 1 s) rather than sleeping a fixed time. With
  nothing selected it pastes nothing. Only the clipboard's text is restored, and a selection
  that is not text (an image) is lost from the clipboard.
