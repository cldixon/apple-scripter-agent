# System recipes: dialogs, appearance, Focus, windows, file moves

System-level tasks that have one right way here, and some that have no scripting API at
all. Each section says which permission the automation must declare.

## Dialogs: asking for text, cancel and focus

```applescript
on run argv
    try
        tell application "System Events"
            activate
            set answer to display dialog "Remind me about:" default answer "" ¬
                with title "Add to Inbox" buttons {"Cancel", "Add"} ¬
                default button "Add" cancel button "Cancel" giving up after 100
        end tell
    on error errorMessage number errorNumber
        if errorNumber is -128 then return ""        -- the user pressed Cancel
        error errorMessage number errorNumber
    end try
    if gave up of answer then return ""             -- no answer in time
    return text returned of answer
end run
```

- **Cancel raises error -128** ("User canceled"). Uncaught, it fails the step and the run.
  Catch it and return "" (or a message) when cancelling is a normal choice, and make the
  later steps handle "".
- **Focus**: automations run in the background runner, so a plain `display dialog` can open
  behind the frontmost window. Showing it from System Events after `activate` brings it to
  the front; that needs `automation:com.apple.systemevents`.
- **Timeouts**: the step's `timeout` must be longer than the person needs to answer
  (60–120 s), and `giving up after` a little shorter than the timeout, so the dialog closes
  itself instead of the step being killed.
- `display dialog` returns a record: `button returned`, `text returned` (with `default
  answer`), `gave up` (with `giving up after`).
- `choose from list {"A", "B"}` returns a list, or `false` on Cancel (no error).
- `display alert "Title" message "Details" as critical` for warnings.
- Use dialogs only when the automation really needs input; hotkey automations should
  otherwise act at once and report with `notify`.

## Appearance: dark mode

```applescript
tell application "System Events"
    tell appearance preferences
        set dark mode to not dark mode     -- toggle
        set isDark to dark mode            -- read
    end tell
end tell
```

- Permission: `automation:com.apple.systemevents` only; this is not UI scripting, so no
  Accessibility.
- `set dark mode to true` / `false` sets a fixed appearance. What happens when the user's
  Appearance is set to Auto has not been verified here.
- From the shell, `defaults read -g AppleInterfaceStyle` prints `Dark` in dark mode and
  fails (exit 1) in light mode; writing that default does not switch the running system,
  so use System Events to change it.
- The harness cannot see appearance; check the result with `run_snippet` reading
  `dark mode of appearance preferences`.

## Focus and Do Not Disturb need a Shortcut

There is **no** AppleScript, JXA or command-line API for Focus modes (Do Not Disturb,
Work, Sleep...). Old recipes that write `com.apple.notificationcenterui` defaults or click
the menu bar no longer work on current macOS. The supported route is Shortcuts:

1. Ask the user to create a shortcut, with an exact name, for example
   "Turn On Do Not Disturb": Shortcuts > New Shortcut > add **Set Focus** > choose
   "Turn Do Not Disturb On" and "Until Turned Off" (or "for 1 hour"). A second shortcut
   with "Turn Do Not Disturb Off" undoes it.
2. Confirm it exists with `list_shortcuts`; names must match exactly, including case.
3. Run it with a `shortcut` step: `{"type": "shortcut", "name": "Turn On Do Not Disturb",
   "timeout": 20}`. Shortcut steps need no permissions in the manifest.

Explain this to the user rather than inventing an API. To read the current Focus, a shortcut
with **Get Current Focus** (recent macOS versions; check the user's Shortcuts) can return it
as the shortcut step's output.

## Window position and size with System Events

```applescript
tell application "System Events"
    set frontApp to first application process whose frontmost is true
    tell frontApp
        if (count of windows) is 0 then return "No window"
        set {x, y} to position of window 1
        set {w, h} to size of window 1
        set position of window 1 to {0, 25}
        set size of window 1 to {800, 600}
    end tell
end tell
```

- Needs `accessibility` and `automation:com.apple.systemevents`.
- Coordinates are points, origin at the **top-left of the primary screen**, y growing
  downwards; screens left of or above the primary one have negative coordinates.
- `window 1` is usually the front window; the focused one has `AXMain` true:
  `value of attribute "AXMain" of w`. Full-screen windows (`AXFullScreen` true), minimized
  windows and fixed-size windows refuse changes.
- Set position, then size, then position again: apps may adjust a size that would cross a
  screen edge, or move the window while resizing.
- System Events cannot tell you the screen sizes; use AppKit's `NSScreen` from JXA (next
  section). `bounds of window of desktop` from Finder gives the whole desktop, not one
  screen, and ignores the menu bar and Dock.

## Screens and coordinates in JXA

```javascript
ObjC.import("AppKit");
const screens = $.NSScreen.screens;                       // [0] is the primary screen
const primaryHeight = screens.objectAtIndex(0).frame.size.height;
function toTopLeft(r) {                                   // AppKit rect -> System Events
    return { x: r.origin.x, y: primaryHeight - (r.origin.y + r.size.height),
             width: r.size.width, height: r.size.height };
}
const list = [];
for (let i = 0; i < screens.count; i++) {
    const s = screens.objectAtIndex(i);
    list.push({ frame: toTopLeft(s.frame), visible: toTopLeft(s.visibleFrame) });
}
```

- AppKit puts the origin at the **bottom-left** of the primary screen with y growing
  upwards; convert with `top = primaryHeight - (origin.y + height)`.
- `visibleFrame` excludes the menu bar and the Dock; use it for "fill the left half".
- "The screen it is on": the screen whose frame overlaps the window the most; when none
  does, the nearest one. `NSScreen.mainScreen` is the screen with keyboard focus, not
  necessarily the window's screen.
- Structs come back as plain objects (`frame.origin.x`, `frame.size.width`).
- Set the window with System Events in the same script:
  `win.position = [x, y]; win.size = [w, h];`. The full example is
  `Examples/window-left-half/scripts/left-half.js`.

## Safe file moves in zsh

```zsh
#!/bin/zsh
emulate -L zsh
zmodload -F zsh/stat b:zstat; zmodload zsh/datetime
folder=${AUTOMATION_VAR_folder:-$HOME/Downloads}
cutoff=$(( EPOCHSECONDS - 30 * 86400 ))
for f in $folder/*(N.on); do                 # regular files, sorted, no error when empty
  zstat -A mtime +mtime -- $f || continue
  (( mtime[1] <= cutoff )) || continue
  strftime -s month %Y-%m $mtime[1]
  dest=$folder/Archive/$month; name=${f:t}; target=$dest/$name; n=2
  while [[ -e $target ]]; do target="$dest/${name:r} $n.${name:e}"; (( n++ )); done
  mkdir -p -- $dest && mv -n -- $f $target && [[ ! -e $f ]] || print -u2 -r -- "skipped $f"
done
```

- Glob qualifiers replace `find` for one folder: `(.)` regular files, `(/)` folders,
  `(N)` no error when nothing matches, `(m+30)` modified more than 30 days ago, `(on)`
  sorted by name. `find "$folder" -maxdepth 1 -type f -mtime +30` is the portable form.
- **Never overwrite**: pick a free name first (" 2", " 3"...) and still use `mv -n`. `mv -n`
  may skip silently, so check the source is gone. Handle names without an extension
  (the loop above would add a stray dot: see the full example).
- Quote every path or use zsh arrays: names contain spaces, quotes and newlines.
- BSD tools differ from GNU: `stat -f %m` (not `-c`), `date -r <seconds>`, `sed -i ''`.
- `~/Downloads`, `~/Documents` and `~/Desktop` are privacy-protected: the first access
  from the runner shows a "would like to access files in your Downloads folder" prompt.
- To trash instead of moving, use Finder's `delete` (it keeps Put Back); it is destructive too.

## Dry runs and destructive automations

- Mark `"destructive": true` for anything that moves, deletes, overwrites or sends. The
  install card then asks twice and offers no Install Anyway.
- Give such scripts a dry-run input that prints the plan without changing anything, and use
  it while exploring: `AUTOMATION_VAR_dryRun=1 zsh script.sh` with `run_snippet`, or point
  `AUTOMATION_VAR_folder` at a folder made with `mktemp -d`. Never run the real move on the
  user's files during drafting.
- Print a summary line first and one line per change after it; the run log keeps the output,
  and a later step can take the first line for the notification:
  `print -r -- "${AUTOMATION_VAR_report%%$'\n'*}"`.
- Make it idempotent: running twice must not move or rename anything a second time.
- `Examples/archive-downloads` is the complete pattern.
