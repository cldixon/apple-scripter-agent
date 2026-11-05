# App recipes: browsers, Finder, Reminders, Calendar

Scripting the apps the everyday backlog touches, with the edge cases that break naive
scripts. Check the app's own dictionary with `introspect_app` before relying on a property:
dictionaries change between macOS versions.

## Safari and Chrome: front tab title and URL

Safari (`automation:com.apple.Safari`), JXA. Check `running()` first so a hotkey does not
launch Safari; walk the windows front to back because the front window can be Settings or
another window without tabs, and an empty new tab has no URL.

```javascript
function run(argv) {
    const safari = Application("Safari");
    if (!safari.running()) return "{}";
    for (const win of safari.windows()) {
        try {
            const tab = win.currentTab();
            const url = tab.url() || "";
            if (url) return JSON.stringify({ title: tab.name() || "", url: url });
        } catch (error) { /* a window without tabs */ }
    }
    return "{}";
}
```

AppleScript equivalent:

```applescript
if application "Safari" is not running then return ""   -- checked without launching it
tell application "Safari"
    if (count of windows) is 0 then return ""
    try
        set theURL to URL of current tab of front window
        set theTitle to name of current tab of front window
    on error
        return ""
    end try
end tell
```

Google Chrome (`automation:com.google.Chrome`): `active tab` instead of `current tab`, and
`title` instead of `name`:

```applescript
tell application "Google Chrome"
    if (count of windows) > 0 then
        set theURL to URL of active tab of front window
        set theTitle to title of active tab of front window
    end if
end tell
```

Other Chromium browsers (Brave, Edge, Arc) use Chrome's dictionary under their own names
and bundle ids; Firefox has no scripting dictionary (UI scripting only).

Markdown links: escape `\`, `[` and `]` in the title, and percent-encode spaces, `(` and
`)` in the URL. Fall back to the URL when the title is empty:

```javascript
const text = (title.replace(/\s+/g, " ").trim() || url).replace(/[\\\[\]]/g, "\\$&");
const dest = url.replace(/ /g, "%20").replace(/\(/g, "%28").replace(/\)/g, "%29");
return "[" + text + "](" + dest + ")";
```

The first run shows the macOS Automation consent prompt for the browser; until the user
allows it, the script fails with -1743.

## Copy only when there is something

`writeClipboard` always writes, so a step that found nothing would clear the clipboard. When
"nothing" is possible (no selection, no window), copy from the script and return the
message to show:

```javascript
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    const text = String(input.paths || "");
    if (!text) return "Nothing is selected in Finder, so nothing was copied.";
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    app.setTheClipboardTo(text);
    return "Copied " + text.split("\n").length + " item(s)";
}
```

Follow it with `notify` using `{{message}}`. Standard Additions on the current application
need no Automation permission.

## Finder selection edge cases

```applescript
tell application "Finder"
    set theSelection to selection
    if theSelection is {} then return ""
    set selectedItems to theSelection as alias list
end tell
set paths to {}
repeat with a in selectedItems
    set end of paths to POSIX path of (contents of a)
end repeat
set AppleScript's text item delimiters to linefeed
set joined to paths as text
set AppleScript's text item delimiters to ""
return joined
```

- `selection` is the selection of the front Finder window, or of the desktop when the
  desktop is frontmost. Finder does not need to be the frontmost app.
- An empty selection is `{}`: decide what to do (return "" and say so) instead of failing.
- `as alias list` converts the whole selection in one Apple Event; `get selection` gives
  Finder references, which `POSIX path of` does not accept directly.
- Folders' paths end with `/`; paths can contain spaces, quotes and non-ASCII characters.
  Join with `linefeed`, not `return`, and quote them (`quoted form of`) for the shell.
- Items in some sidebar views (Recents, tags, search results) are real files and convert
  normally; items inside a package look like files.
- The target of the front window: `(target of front Finder window) as alias`; with no window,
  use `insertion location` or `path to desktop`.

## Reminders: lists, creating and due dates

```applescript
set now to current date
set today to now - (time of now)                 -- midnight today
tell application "Reminders"
    if not (exists list "Inbox") then make new list with properties {name:"Inbox"}
    tell list "Inbox"
        set r to make new reminder with properties {name:"Call Ann", body:"About the report"}
    end tell
    set allday due date of r to today            -- due today, no time, no alert
    -- set due date of r to today + 17 * hours   -- due today at 17:00
    -- set remind me date of r to today + 9 * hours  -- an alert at 09:00
end tell
```

- Permission: `automation:com.apple.reminders`. Reminders can be slow to answer the first
  Apple Event after launch: give the step a 30–60 s timeout.
- `list "Inbox"` matches by name in any account; the first match wins. `make new list`
  creates it in the default account. `default list` is where new reminders go by default.
- `due date` is a date and time; `allday due date` is a day without time. If a script must
  run on an older macOS whose dictionary lacks `allday due date`, check with
  `introspect_app` first (an unknown term does not compile).
- Open reminders: `reminders of list "Inbox" whose completed is false`.
- Sections, tags, subtasks, URLs and early reminders are not scriptable; use a Shortcut
  with the Reminders actions.

## Calendar: fast queries for today

```applescript
set now to current date
set dayStart to now - (time of now)
set dayEnd to dayStart + 1 * days
tell application "Calendar"
    repeat with c in (every calendar)
        set todays to (every event of c whose start date < dayEnd and end date > dayStart)
        repeat with e in todays
            set t to summary of e
            set s to start date of e
            set isAllDay to allday event of e
        end repeat
    end repeat
end tell
```

- Permission: `automation:com.apple.iCal` (Calendar's bundle id is still `com.apple.iCal`).
- `whose` is evaluated by Calendar and is the fast path; looping over `every event` in the
  script sends one Apple Event per property per event and can take minutes.
- Bulk reads are fast too: `summary of every event of c` returns a whole list in one event.
- "Overlaps today" is `start date < dayEnd and end date > dayStart`; that includes events
  that started yesterday and are still running, and all-day events.
- Subscribed and delegated calendars can be slow or fail: wrap each calendar in `try`, but
  rethrow -1712 (timeout) and -1743 (permission denied) so an error does not look like an
  empty day.
- Give the step a 60 s timeout; check real durations in the run log.
- Format times from date components (`hours of d`, `minutes of d`), not `time string of`,
  which follows the user's locale.

## Calendar: repeating and all-day events

- **Repeating events**: Calendar stores a series as one event with a `recurrence` rule
  (an RFC 5545 RRULE such as `FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE`) and its *first* start
  date. `whose start date ...` therefore finds only the first occurrence; today's
  occurrence of a series that started last month is not returned.
- To include them, read `recurrence of every event of c` (one Apple Event per calendar),
  pick the items that are not `missing value`, and expand their rules yourself. Excluded
  occurrences are in `excluded dates`. `Examples/today-events/scripts/format-events.js`
  expands DAILY, WEEKLY, MONTHLY and YEARLY rules with INTERVAL, COUNT, UNTIL, BYDAY,
  BYMONTHDAY and BYMONTH, and reports anything else as "not checked".
- How Calendar exposes a single moved or edited occurrence of a series has not been
  verified here; test with the user's data.
- **All-day events** have `allday event` true; their start date is midnight and their end
  date is the following midnight (so a one-day event "ends" tomorrow at 00:00). Show them
  without a time, and do not drop them for having "started" before now.
- A Shortcut with **Find Calendar Events** (filter: Start Date is today) expands repeating
  events for you; it is a good alternative when the user is willing to create one.
- EventKit from JXA (`ObjC.import("EventKit")`) needs the Calendars privacy permission for
  the runner process; it is not a supported route here.
