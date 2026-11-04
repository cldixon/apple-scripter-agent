# Shortcuts and app intents

When to reach for the Shortcuts app, and how to run shortcuts from automations.

## When to use a shortcut

Use a `shortcut` step when the job needs something AppleScript, JXA and the shell cannot
reach, and the user already has (or can build) a shortcut for it:

- App Intents that apps expose only to Shortcuts (many third-party apps, and Apple apps such
  as Notes, Freeform, Home, Weather, Maps, Translate).
- Focus modes ("Set Focus"), some Control Center and system toggles ("Set Appearance",
  "Set Bluetooth", "Set Wi-Fi", "Set Low Power Mode", "Set Stage Manager").
- Image and media actions that would otherwise need extra tools.
- HomeKit scenes and accessories.

Automations cannot create or edit shortcuts. If none exists, tell the user which actions to
add in the Shortcuts app and what to name it, then use `list_shortcuts` to confirm the exact
name before writing the step.

## The shortcut step

```json
{ "type": "shortcut", "name": "Resize Image", "input": "{{path}}", "as": "result", "timeout": 60 }
```

- `name` must match the shortcut's name exactly (case and spacing). `list_shortcuts` returns
  the names the runner can see.
- `input` is templated, written to a temporary file and passed with `--input-path`. The
  shortcut receives it as text (or as a file, depending on how its first action reads it).
- The output is whatever the shortcut's last action outputs ("Stop and Output" or the final
  result), read from `--output-path`. Text outputs arrive as text; files may arrive as their
  contents, so make the shortcut end with a text action when the next step needs text.
- Shortcuts can be slow to start (a second or more): give the step a generous `timeout`.
- The first time a shortcut touches a protected resource, macOS or Shortcuts may show a
  privacy prompt, which blocks the run until answered. Run it once by hand first.

## The shortcuts command

```zsh
shortcuts list                               # every shortcut name, one per line
shortcuts list --folder-name "Automation"    # one folder
shortcuts list --show-identifiers            # names with their UUIDs
shortcuts run "Name"                         # run it
shortcuts run "Name" --input-path in.txt --output-path out.txt
print -r -- "hello" | shortcuts run "Uppercase" | cat   # stdin and stdout also work for text
shortcuts run "Make PDF" -i photo.jpg -o out.pdf --output-type com.adobe.pdf
shortcuts view "Name"                        # open it in the Shortcuts editor
```

`shortcuts run` exits non-zero when the shortcut fails or does not exist, with the reason on
stderr. It cannot pass parameters other than one input; pack several values as JSON text
and parse it in the shortcut with "Get Dictionary from Input".

## Running shortcuts from AppleScript and JXA

```applescript
tell application "Shortcuts Events"
    set result to run shortcut "Uppercase" with input "hello"
end tell
```

From JXA, the same command is `run` on the Shortcuts Events application object with the
shortcut as the direct parameter and `{withInput: ...}`; check the exact form with
`introspect_app("Shortcuts Events", "run")` and `run_snippet` before relying on it. The
AppleScript form above is the most widely used.

- "Shortcuts Events" (`com.apple.shortcuts.events`) runs shortcuts in the background without
  opening the Shortcuts app. Declare `automation:com.apple.shortcuts.events`.
- `tell application "Shortcuts"` can list shortcuts (`name of every shortcut`) but running
  through it opens the app; prefer "Shortcuts Events".
- The result is a list when the shortcut outputs several items.

## URL schemes

```zsh
open "shortcuts://run-shortcut?name=Morning%20Routine"
open "shortcuts://run-shortcut?name=Uppercase&input=text&text=hello"
open "shortcuts://open-shortcut?name=Uppercase"
```

URL runs open the Shortcuts app and return immediately without output. Use them only when
the output does not matter; the `shortcut` step is better for everything else.

## Choosing between Shortcuts, scripting and UI scripting

1. App scripting (AppleScript/JXA against the app's dictionary): fastest and most reliable
   when the app is scriptable. Check with `list_apps` and `introspect_app`.
2. Shell tools: for system settings that have a command (`defaults`, `pmset`,
   `networksetup`, `open`).
3. Shortcuts: for App Intents, Focus, Home and actions with no scripting interface.
4. UI scripting through System Events (clicking menus and buttons): last resort. It needs
   Accessibility permission, breaks when the app's interface changes, and moves the user's
   focus. Menu items are more stable than buttons.

Explain the trade-off to the user when the only route is UI scripting or a shortcut they
must build themselves.
