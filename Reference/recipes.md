# Recipes and gotchas

Idioms that come up again and again in automations, with the pitfalls that break them.
Each recipe is self-contained; adapt names and paths. Test pieces with `run_snippet`.

## The step input and output contract

Every script step receives the named outputs of earlier steps (their `"as"` names) as one
JSON object, and its own output is what it returns or prints (one trailing newline removed).

| Language | Input | Output |
| --- | --- | --- |
| AppleScript | `on run argv` → `item 1 of argv` (JSON text) | the run handler's return value |
| JXA | `function run(argv)` → `JSON.parse(argv[0])` | the return value of `run` (return a string) |
| shell | `$AUTOMATION_INPUT` (JSON), `$AUTOMATION_VAR_<name>` per value | stdout |
| shortcut | the step's `input` (templated) | the shortcut's output |

Primitive steps and `input` fields can use `{{name}}` to insert an earlier output and
`{{today:yyyy-MM-dd}}` for the date. A typical chain:

```json
"steps": [
  { "type": "primitive", "action": "readClipboard", "as": "clip" },
  { "type": "jxa", "file": "scripts/clean.js", "as": "cleaned" },
  { "type": "primitive", "action": "writeClipboard", "text": "{{cleaned}}" },
  { "type": "primitive", "action": "notify", "title": "Cleaned", "text": "{{cleaned}}" }
]
```

All values are text. Return numbers and booleans as text, and lists as text joined with
line breaks (or JSON from JXA).

## Reading the JSON input in AppleScript

For one or two values, the easiest route is the per-value template in a primitive step or
a shell variable. To parse the JSON in AppleScript, use Foundation:

```applescript
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

on run argv
    set input to my parseJSON(item 1 of argv)
    set clip to input's objectForKey:"clip"
    if clip is missing value then return ""
    return clip as text
end run

on parseJSON(jsonText)
    set ca to current application
    set jsonData to (ca's NSString's stringWithString:jsonText)'s dataUsingEncoding:(ca's NSUTF8StringEncoding)
    return ca's NSJSONSerialization's JSONObjectWithData:jsonData options:0 |error|:(missing value)
end parseJSON
```

Or convert it to an AppleScript record: `(ca's NSDictionary's dictionaryWithDictionary:obj) as record`
(keys become record labels; it fails for keys that are not valid identifiers, so prefer
`objectForKey:`). JXA is simpler for anything structured.

## Text item delimiters: split, join, replace

```applescript
on splitText(theText, separator)
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set parts to text items of theText
    set AppleScript's text item delimiters to saved
    return parts
end splitText

on joinText(theList, separator)
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joined to theList as text
    set AppleScript's text item delimiters to saved
    return joined
end joinText

on replaceText(theText, findText, replacement)
    return joinText(splitText(theText, findText), replacement)
end replaceText
```

- Always save and restore the delimiters: they are global to the script and affect every
  later `as text` coercion of a list.
- The delimiter can be a list (`{",", ";"}`) to split on any of several strings.
- Delimiter matching follows the current `considering`/`ignoring case` setting (by default
  it ignores case).
- For regular expressions use JXA (`text.replace(/\s+/g, " ")`) or
  `do shell script "sed -E ..."` with `quoted form of`.

## Trimming and cleaning text

```javascript
// JXA: trim, collapse spaces, strip blank lines
function run(argv) {
    const input = JSON.parse(argv[0]);
    return input.clip
        .split(/\r?\n/)
        .map(line => line.replace(/\s+/g, " ").trim())
        .filter(line => line.length > 0)
        .join("\n");
}
```

```applescript
on trimText(t)
    set ws to {space, tab, return, linefeed, character id 160}
    repeat while t is not "" and (character 1 of t) is in ws
        set t to text 2 thru -1 of t
    end repeat
    repeat while t is not "" and (character -1 of t) is in ws
        set t to text 1 thru -2 of t
    end repeat
    return t
end trimText
```

`text 2 thru -1` of a one-character string fails; the `t is not ""` guards handle that.

## Paths: POSIX path, alias, file and HFS

```applescript
set p to "/Users/me/Desktop/report.pdf"
set f to POSIX file p                  -- a file reference (works even if it does not exist)
set a to (POSIX file p) as alias       -- an alias: fails (-43) if the file does not exist
POSIX path of a                        -- "/Users/me/Desktop/report.pdf"
POSIX path of (path to desktop)        -- "/Users/me/Desktop/" (folders end with /)
(path to desktop) as text              -- "Macintosh HD:Users:me:Desktop:" (HFS path)
tell application "Finder" to set a to (item 1 of (get selection)) as alias
quoted form of POSIX path of a         -- safe for do shell script
```

- Finder items are Finder references; convert them with `as alias` before `POSIX path of`.
- `POSIX file "/x"` inside a `tell application "Finder"` block can be misread; build it
  outside the block, or write `(POSIX file "/x") as alias`.
- `~` is not expanded by AppleScript: use `POSIX path of (path to home folder)`.
- In JXA, use `Path("/x")` for file parameters and plain strings everywhere else.
- In the shell, quote every path: `"$path"`. Paths from the user can contain spaces,
  quotes and non-ASCII characters.

## Reading and writing files

```applescript
-- Read UTF-8 text
set t to read (POSIX file "/Users/me/notes.txt") as «class utf8»

-- Write UTF-8 text, replacing the file
on writeText(t, posixPath)
    set fileRef to open for access (POSIX file posixPath) with write permission
    try
        set eof of fileRef to 0
        write t to fileRef as «class utf8»
        close access fileRef
    on error errorMessage number errorNumber
        close access fileRef
        error errorMessage number errorNumber
    end try
end writeText
```

- Without `as «class utf8»`, `read` and `write` use the legacy MacRoman encoding and
  garble non-ASCII text.
- Always `close access` (also on error), or the file stays open until the script ends.
- Appending: skip `set eof` and write `starting at eof`.
- Shell alternatives: `cat file`, `print -r -- "$text" > file`, `>> file` to append.
- JXA: see "The Objective-C bridge" in jxa-essentials (`stringWithContentsOfFileEncodingError`).

## The clipboard

| Where | Read | Write |
| --- | --- | --- |
| primitive step | `{"action": "readClipboard", "as": "clip"}` | `{"action": "writeClipboard", "text": "{{x}}"}` |
| AppleScript | `the clipboard as text` | `set the clipboard to "x"` |
| JXA | `app.theClipboard()` (with `includeStandardAdditions`) | `app.setTheClipboardTo("x")` |
| shell | `pbpaste` | `print -rn -- "$x" \| pbcopy` |

- `the clipboard` without `as text` can return styled text or a record; coerce it.
- Prefer the primitives: they need no permission and are easy to unit test (`clipboard`
  in a unit test sets the starting clipboard).
- To paste into the frontmost app, use the `pasteText` primitive (needs Accessibility)
  rather than scripting ⌘V yourself.

## Notifications and feedback

```applescript
display notification "Copied 3 paths" with title "Finder" subtitle "Clipboard" sound name "Glass"
```

- The `notify` primitive is the simplest way to report a result; it is shown as coming
  from the runner.
- `display notification` from `osascript` may be attributed to Script Editor or not shown
  at all depending on notification settings; the primitive is more dependable.
- Avoid `display dialog` in hotkey automations: it blocks until answered and steals focus.
  If a choice is really needed, `choose from list` returns `false` on Cancel.
- `say "Done"` gives audio feedback with no permissions.

## Dates

```applescript
-- ISO 8601 date without locale problems
on isoDate(d)
    set y to year of d as integer
    set m to month of d as integer
    set dd to day of d
    return (y as text) & "-" & text -2 thru -1 of ("0" & m) & "-" & text -2 thru -1 of ("0" & dd)
end isoDate

set now to current date
set tomorrow to now + 1 * days            -- also: hours, minutes, weeks
set startOfDay to now - (time of now)     -- time = seconds since midnight
set d to current date
set year of d to 2025
set day of d to 1                          -- set the day before the month to avoid overflow
set month of d to March
set hours of d to 9
set minutes of d to 0
set seconds of d to 0
weekday of now                             -- Monday ...
(now - startOfDay) / hours
```

- `date "..."` literals and `as text` depend on the user's locale and region settings:
  build dates from components and format them yourself.
- The `formatDate` primitive formats "now" with a Unicode pattern (`yyyy-MM-dd HH:mm`), and
  templates accept `{{today:EEEE}}`.
- JXA: `new Date().toISOString().slice(0, 10)` is UTC; for local dates use
  `d.getFullYear()`, `d.getMonth() + 1`, `d.getDate()`.
- Shell: `date +%Y-%m-%d`, `date -v+1d +%A` (tomorrow's weekday).

## Lists and text

```applescript
-- list → lines
set AppleScript's text item delimiters to linefeed
set out to theList as text
set AppleScript's text item delimiters to ""

-- lines → list
set theLines to paragraphs of theText

-- dedupe
set unique to {}
repeat with x in theList
    if unique does not contain (contents of x) then set end of unique to (contents of x)
end repeat

-- sort (text, one item per line)
set sorted to paragraphs of (do shell script "printf '%s\\n' " & quoted form of out & " | sort -f")
```

In JXA, use arrays: `[...new Set(xs)]`, `xs.sort((a, b) => a.localeCompare(b))`,
`xs.join("\n")`.

## Finder: selection, front window and files

```applescript
tell application "Finder"
    set sel to selection as alias list            -- aliases of selected items ({} if none)
    if (count of sel) is 0 then error "Select something in Finder first." number 1001
    if (count of Finder windows) > 0 then
        set here to (target of front Finder window) as alias
    else
        set here to (path to desktop) as alias
    end if
    set newFolder to make new folder at here with properties {name:"New"}
    move (every file of here whose name extension is "png") to newFolder
    reveal newFolder
end tell
set paths to {}
repeat with a in sel
    set end of paths to POSIX path of a
end repeat
```

- `selection as alias list` is the reliable conversion; `get selection` returns Finder
  references.
- `insertion location` is the folder a new item would go to (the front window or desktop).
- Moving and deleting (`delete` moves to the Trash) are destructive: mark the manifest.
- For many files, shell tools (`mv`, `find`) are faster than Finder; Finder is better when
  the user expects Finder behavior (Trash, reveal, labels).

## Mail

```applescript
tell application "Mail"
    -- Selected messages in the front viewer
    set msgs to selection
    repeat with m in msgs
        set s to subject of m
        set fromWho to sender of m          -- "Name <address>"
        set body to content of m
        set received to date received of m
    end repeat

    -- Unread count and messages
    set n to unread count of inbox
    set unreadSubjects to subject of (messages of inbox whose read status is false)

    -- Compose (shown to the user, not sent)
    set newMessage to make new outgoing message with properties ¬
        {subject:"Weekly report", content:"Hi," & return & return, visible:true}
    tell newMessage
        make new to recipient at end of to recipients with properties {address:"ann@example.com"}
    end tell
end tell
```

- `send newMessage` sends immediately: that is destructive (it sends a message) and must be
  marked; prefer leaving the draft visible for the user.
- `inbox` is the unified inbox; a specific mailbox is `mailbox "Archive" of account "iCloud"`.
- Reading `content` of many messages is slow; filter with `whose` first.

## Calendar

```applescript
tell application "Calendar"
    set startDate to current date
    set hours of startDate to 14
    set minutes of startDate to 0
    set seconds of startDate to 0
    tell calendar "Work"
        make new event with properties {summary:"Review", start date:startDate, ¬
            end date:startDate + 30 * minutes, location:"Room 2"}
    end tell
    set dayStart to (current date) - (time of (current date))
    set todays to summary of (every event of calendar "Work" whose start date ≥ dayStart ¬
        and start date < dayStart + 1 * days)
end tell
```

- Calendar names must match exactly (`name of every calendar`).
- `whose` queries on events are slow on large calendars and do not expand repeating
  events (only the first occurrence matches). For "what is on today", `icalBuddy` is not
  installed; consider a shortcut with "Find Calendar Events".
- `allday event:true` for all-day events.
- Permission: `automation:com.apple.iCal`. Expanding repeating events and listing today's
  events: see recipes-apps, "Calendar: repeating and all-day events".

## Reminders

```applescript
tell application "Reminders"
    set due to (current date) + 1 * days
    tell list "Reminders"
        make new reminder with properties {name:"Call Ann", body:"About the report", due date:due}
    end tell
    set openItems to name of (reminders of list "Reminders" whose completed is false)
    set completed of (first reminder of list "Reminders" whose name is "Call Ann") to true
end tell
```

- `default list` is the list new reminders go to by default: `tell default list to make ...`.
- `remind me date` sets an alert; `due date` alone shows the date without an alert.
- `priority`: 0 none, 1 high, 5 medium, 9 low.
- Sections, tags and subtasks are not in the scripting dictionary; use a shortcut.

## Notes

```applescript
tell application "Notes"
    tell account "iCloud"
        make new note at folder "Notes" with properties {name:"Meeting", body:"<h1>Meeting</h1><p>Agenda</p>"}
    end tell
    set titles to name of every note of folder "Notes" of account "iCloud"
    set plain to plaintext of note "Meeting" of folder "Notes" of account "iCloud"
end tell
```

- `body` is HTML; `plaintext` is read-only text. Setting `body` replaces the whole note,
  including its title line.
- Account and folder names vary ("iCloud", "On My Mac"); read them first.
- Locked notes cannot be read.

## Safari

```applescript
tell application "Safari"
    set pageURL to URL of current tab of front window
    set pageTitle to name of current tab of front window
    make new document with properties {URL:"https://example.com"}   -- new window
    tell front window to set current tab to (make new tab with properties {URL:"https://example.com"})
    set allURLs to URL of every tab of every window
end tell
```

- `do JavaScript "document.title" in current tab of front window` only works when the
  user has enabled Settings > Advanced > "Show features for web developers" and then
  Develop > "Allow JavaScript from Apple Events". Tell the user if it fails.
- `front window` fails (-1728) when no window is open; check `count of windows`.
- Chrome uses `active tab` instead of `current tab` and `execute javascript`.

## Music

```applescript
tell application "Music"
    if player state is playing then
        set nowPlaying to name of current track & " — " & artist of current track
    end if
    playpause
    next track
    set sound volume to 40
    play playlist "Focus"
    set loved of current track to true   -- "favorited" on recent macOS
end tell
```

- `current track` fails when nothing is loaded; check `player state is not stopped`.
- Starting playback launches Music; check `application "Music" is running` when that
  would be unwelcome.

## System Events vs app scripting

System Events (`com.apple.systemevents`) is a faceless app that scripts the system itself:

- processes: `name of every process whose background only is false`,
  `name of first process whose frontmost is true`, `bundle identifier of ...`
- UI scripting (needs Accessibility), keystrokes and clicks
- `property list file`, `disk item`, `folder`, `file` (fast file access without Finder)
- `appearance preferences` (`set dark mode of appearance preferences to true`)
- `login items`, `current user`, `screen saver preferences`

Use app scripting (the app's own dictionary) whenever the app supports it; use System
Events for system state and as the UI-scripting fallback. Both need an `automation:`
permission for the target; UI scripting also needs `accessibility`.

```applescript
tell application "System Events"
    set frontApp to name of first application process whose frontmost is true
    set frontID to bundle identifier of first application process whose frontmost is true
    set dark mode of appearance preferences to not dark mode of appearance preferences
end tell
```

## UI scripting basics

```applescript
tell application "TextEdit" to activate
tell application "System Events"
    tell process "TextEdit"
        click menu item "New" of menu "File" of menu bar 1
        delay 0.3
        keystroke "Hello"
        keystroke "s" using {command down}
        key code 36                      -- return
        set winTitle to name of front window
        click button "Cancel" of sheet 1 of front window
    end tell
end tell
```

- Activate the app first; keystrokes go to the frontmost app.
- `delay` after actions that open windows or sheets; poll with
  `repeat until exists sheet 1 of front window` (with a limit) rather than long delays.
- Find element names by exploring: `entire contents of front window` (slow) or
  `UI elements of front window`, `name of every menu item of menu "File" of menu bar 1`.
- Menu titles are localized; prefer menu items over buttons, and keyboard shortcuts over
  both when the app has one.
- `key code` numbers: return 36, tab 48, space 49, delete 51, escape 53, left 123,
  right 124, down 125, up 126.

## Frontmost app, windows and launching

```applescript
tell application "System Events"
    set frontApp to first application process whose frontmost is true
    set appName to name of frontApp
    set winName to name of front window of frontApp      -- needs Accessibility
end tell
if application "Slack" is running then tell application "Slack" to quit
tell application "Notes" to activate
tell application id "com.apple.TextEdit" to launch       -- launch without bringing to front
```

- `launchApp` and `openURL` primitives need no Apple Events and no permissions.
- `quit` an app with unsaved documents shows a save dialog; `quit saving no` discards
  changes (destructive).

## do shell script from AppleScript

```applescript
set p to POSIX path of (path to desktop)
set listing to do shell script "ls -1 " & quoted form of p
set n to (do shell script "/usr/bin/pmset -g batt | grep -Eo '[0-9]+%' | head -1")
do shell script "open -a Safari " & quoted form of "https://example.com"
```

- Always pass data through `quoted form of`; never concatenate raw user text.
- It runs `/bin/sh` with a minimal PATH: use absolute paths for anything outside
  `/usr/bin:/bin:/usr/sbin:/sbin`.
- Output line endings become `return` (CR); use `paragraphs of` to split.
- A non-zero exit raises an error whose number is the exit status.
- `with administrator privileges` shows a password dialog: do not use it in automations.

## Writing tests for an automation

- `unit` tests run one step (and the steps before it) in a recording environment with a
  fixed `clock` and `clipboard`, and compare its output with `expect`. They suit
  primitive chains and pure text transformations.
- Script steps (AppleScript, JXA, shell, shortcut) do not run in unit tests: the recording
  environment returns an empty output for them. Test scripts with `run_snippet` while
  drafting, and rely on the compile checks that validation runs for every script.
- `harness` tests run the whole automation while the runner's own test window is focused
  and compare the window's text with `expectText` (for typing and pasting automations).
- Every draft is validated before installing: static checks, compile checks of every
  script, unit tests and harness tests. Fix what fails, rewrite the draft, validate again.
