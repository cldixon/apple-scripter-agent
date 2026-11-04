# Permissions and errors

macOS privacy permissions (TCC: Transparency, Consent and Control) that automations run
into, how this app declares and checks them, and what common error numbers mean.

## Who needs the permission

Automations run inside "Automation Agent Runner" (bundle id
`dev.cldixon.AutomationAgent.Runner`). Scripts are child processes (`osascript`, `zsh`,
`shortcuts`), and macOS attributes their requests to the runner, the responsible process.
So every permission below is granted to Automation Agent Runner, not to Terminal, osascript
or the main app. Permissions are tied to the app's code signature.

Declare what a manifest needs in `permissions`:

| Value | Needed for |
| --- | --- |
| `automation:<bundle id>` | every app a script sends Apple Events to (`tell application`, `Application(...)`), including System Events (`com.apple.systemevents`) and Finder (`com.apple.finder`) |
| `accessibility` | typing and pasting primitives, UI scripting through System Events (`click`, `keystroke`, menus), reading other apps' UI |
| `fullDiskAccess` | reading protected data directly: Mail and Messages databases, Safari history and bookmarks, other apps' containers |
| `screenRecording` | `screencapture`, reading other apps' window contents or titles |

Use `check_permissions` before proposing an automation to see what is already granted.
`automation:` checks report `unknown` when the target app is not running.

## Automation (Apple Events)

- macOS asks once per target app, the first time the runner sends it an event: "Automation
  Agent Runner wants access to control Finder". Until the user answers, the script waits.
- After a denial the script fails with -1743 every time, without asking again. The user
  must turn it on in System Settings > Privacy & Security > Automation > Automation Agent
  Runner.
- Sending events to the runner itself, or using Standard Additions outside a `tell` block,
  needs no permission.
- System Events counts as an app: `tell application "System Events"` needs
  `automation:com.apple.systemevents`; UI scripting through it also needs `accessibility`.
- The user can reset all Automation decisions for the runner with
  `tccutil reset AppleEvents dev.cldixon.AutomationAgent.Runner` in Terminal (suggest it,
  do not run it from an automation).

## Accessibility

Needed to post keyboard events (the `typeText` and `pasteText` primitives), and for UI
scripting: `tell application "System Events" to tell process "Safari" to click menu item
"New Window" of menu "File" of menu bar 1`.

- Without it, System Events reports "osascript is not allowed assistive access" or
  "Automation Agent Runner is not allowed assistive access" (-1719 or -25211), and
  synthetic keystrokes are silently dropped.
- Grant it in System Settings > Privacy & Security > Accessibility; the runner's menu has
  "Allow Accessibility…". After a rebuild with a new signature the old entry stops working:
  remove it and add the runner again.

## Full Disk Access and Files & Folders

- Full Disk Access unlocks protected locations: `~/Library/Mail`, `~/Library/Messages`,
  `~/Library/Safari`, `~/Library/Application Support/com.apple.TCC`, other apps'
  containers, Time Machine backups. Grant it in System Settings > Privacy & Security >
  Full Disk Access (add the runner with the + button).
- Prefer scripting the app (Mail, Safari, Messages) over reading its files: it needs only
  the app's Automation permission and survives database format changes.
- Files & Folders prompts cover Desktop, Documents, Downloads, iCloud Drive, removable and
  network volumes. The first access from the runner asks once per location; a denial makes
  file operations fail with "Operation not permitted" (EPERM, error -54 in AppleScript).

## Screen Recording and other privacy areas

- Screen & System Audio Recording: needed by `screencapture` and to read other windows'
  titles and contents. Without it, `screencapture` captures only the desktop wallpaper and
  the menu bar.
- Contacts, Calendars, Reminders and Photos: scripting those apps needs Automation
  permission for the app. Reading their data through frameworks would need the separate
  privacy permission, which the runner does not request.
- Location Services: needed to read the Wi-Fi network name on recent macOS.
- Camera, Microphone and Input Monitoring are not used by automations.

## Error numbers: Apple Events

| Number | Constant | Meaning and fix |
| --- | --- | --- |
| -1743 | errAEEventNotPermitted | Not authorized to send Apple Events to the app. Allow it under Automation; declare `automation:<bundle id>`. |
| -1744 | errAEEventWouldRequireUserConsent | The user has not been asked yet (seen when checking without prompting). |
| -1728 | errAENoSuchObject | "Can't get …": the object does not exist (no selection, empty list, wrong index, closed window). Check `count` or `exists` first. |
| -1708 | errAEEventNotHandled | "… doesn't understand the … message": a command sent to the wrong object or app, often a handler called inside `tell` without `my`. |
| -1719 | errAEIllegalIndex | "Invalid index", or (from System Events) no assistive access: grant Accessibility. |
| -1700 | errAECoercionFail | "Can't make … into type …": wrong type; coerce explicitly or check `class of`. |
| -1712 | errAETimeout | "AppleEvent timed out": wrap long commands in `with timeout of N seconds`. |
| -10000 | errAEEventFailed | The app's handler failed; often a bad parameter. Read the message. |
| -10004 | errAEPrivilegeError | "A privilege violation occurred": Standard Additions (do shell script, display dialog, the clipboard) called inside another app's `tell` block. Move it outside or use `tell me`. |
| -10006 | errAEWriteDenied | "Can't set … to …": the property is read-only. |
| -600 | procNotFound | The application is not running (or quit mid-script). |
| -609 | connectionInvalid | The app quit or crashed while the script talked to it. |
| -128 | userCanceledErr | The user pressed Cancel. Treat it as a normal stop. |

## Error numbers: files, UI scripting and others

| Number | Meaning and fix |
| --- | --- |
| -43 | File or folder not found. Check the path; HFS paths use `:`, POSIX paths use `/`. |
| -48 | A file with that name already exists. |
| -54 | Permission error: the file is locked, or a privacy permission (Files & Folders, Full Disk Access) is missing. |
| -35 | The volume (disk) was not found. |
| -50 | Parameter error: a command got an argument of the wrong kind. |
| -25211 | Accessibility API disabled for the process: grant Accessibility. |
| -2700 | A generic script error raised with `error "…"` without a number. |
| -2741, -2740 | Syntax errors at compile time. |
| -2753 | "The variable … is not defined": used before being set, or set inside a `try` that failed. |
| -10810 | Launch Services could not launch the app. |

For `do shell script`, a non-zero exit status becomes an AppleScript error whose number is
the exit status and whose message is the command's stderr.

## Diagnosing a failing automation

1. Read the run's error: the step index, its type and the message.
2. Permission errors (-1743, -1719, -25211, EPERM, "not allowed") are fixed by the user in
   System Settings, not in the script. Say exactly which pane and which app.
3. "Can't get" (-1728) usually means the expected state is missing: nothing selected, no
   front window, an empty mailbox. Guard with `if (count of ...) is 0 then`.
4. Reproduce with `run_snippet` in small pieces, then fix the script and re-validate the draft.
