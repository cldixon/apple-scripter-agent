# AppleScript essentials

Condensed notes on the AppleScript language for writing automation steps. Search the
reference library for an app's own dictionary (`sdef: <App>`) before guessing its terms.

## How AppleScript steps run here

An `applescript` step runs with `osascript` as a child process of the runner, so Apple
Events are attributed to "Automation Agent Runner" and its Automation permissions apply.

- Input: the first item of `argv` in the `run` handler is a JSON object string with every
  named output so far (`{"paths": "...", "count": "3"}`). AppleScript has no JSON parser;
  either pass simple values through `{{name}}` templates in other steps, use JXA for
  structured input, or parse a single known key (see recipes: "Reading the JSON input").
- Output: whatever the `run` handler returns (coerced to text) is the step's output, with
  one trailing newline removed. A list is returned as items joined by ", "; build the text
  yourself with text item delimiters when you need another separator.
- Errors: an uncaught error fails the step; its message and number go to the run log.
- Timeout: a step is killed after its `timeout` (10 seconds by default). Long Apple Events
  also need `with timeout` (see below).

```applescript
on run argv
    set inputJSON to item 1 of argv
    tell application "Finder" to set n to count of (get selection)
    return n as text
end run
```

A script without an explicit `on run` handler is the implicit run handler; `argv` is then
not available, so declare `on run argv` whenever you need the input.

## Values and classes

| Class | Examples | Notes |
| --- | --- | --- |
| text | `"hello"`, `"tab" & tab & "x"` | `string` and `Unicode text` are synonyms for `text` |
| integer, real | `42`, `3.14`, `1.0E+6` | `number` covers both; `div` and `mod` for integer math |
| boolean | `true`, `false` | `and`, `or`, `not` |
| list | `{1, "two", {3}}` | 1-based; `item -1` is the last |
| record | `{name:"Ann", age:30}` | access with `name of rec`; keys are fixed identifiers |
| date | `current date`, `date "Monday, 1 January 2024 at 09:00:00"` | date literals depend on the user's locale: build dates from parts instead |
| missing value | `missing value` | what apps return for an empty property |
| alias, file, POSIX file | `POSIX file "/tmp/x.txt"`, `alias "Macintosh HD:Users:"` | see recipes for conversions |

`class of x` returns the class. Constants: `return`, `linefeed`, `tab`, `space`, `quote`, `pi`.
`return` is a carriage return (CR); use `linefeed` for Unix line breaks.

## Variables, properties and scope

- `set x to 5` assigns; `copy x to y` makes an independent copy. With lists and records,
  `set y to x` shares the same object: changing `item 1 of y` changes `x` too.
- Variables are local to the handler they are first set in. `global x` declares a
  script-wide variable; `property x : 0` declares a property whose value persists between
  runs of a compiled, saved script (it does not persist here, because scripts are run from
  source every time).
- Inside a `tell application` block, a handler call needs `my`: `my formatDate(d)`, or
  the call is sent to the app and fails with -1708.
- Identifiers are case-insensitive. Use `|pipes|` for identifiers that clash with terms.

## Text

```applescript
set s to "Hello, World"
length of s                      -- 12
text 1 thru 5 of s               -- "Hello"
character 1 of s                 -- "H"
words of s                       -- {"Hello", "World"}
paragraphs of "a" & linefeed & "b" -- {"a", "b"}
offset of "World" in s           -- 8 (0 when absent)
s contains "World"               -- true
s starts with "Hell"             -- true
s & "!"                          -- concatenation
"5" as integer                   -- 5
42 as text                       -- "42"
quoted form of "/tmp/my file"    -- "'/tmp/my file'" for shell commands
id of "A"                        -- 65; character id 65 is "A"
```

- `text 1 thru 5 of s` returns text; `characters 1 thru 5 of s` returns a list.
- `paragraphs` splits on CR, LF and CRLF.
- Comparisons ignore case by default; wrap them in `considering case ... end considering`
  to make them case-sensitive.
- To replace or split text, use text item delimiters (see recipes) or `do shell script`
  with `sed` for regular expressions.
- Text is Unicode; `ASCII character` and `ASCII number` are deprecated, use `character id`
  and `id of`.

## Lists and records

```applescript
set xs to {"a", "b", "c"}
count of xs                    -- 3 (also: length of xs)
item 2 of xs                   -- "b"
items 2 thru 3 of xs           -- {"b", "c"}
set end of xs to "d"           -- append (fast)
set beginning of xs to "z"     -- prepend
xs contains "b"                -- true
reverse of xs
rest of xs                     -- all but the first
repeat with x in xs            -- x is a reference: use (contents of x) when comparing
    log (contents of x)
end repeat
set r to {name:"Ann", age:30}
name of r                      -- "Ann"
set age of r to 31
```

- There is no built-in sort; use `do shell script "sort"` on text, or the ObjC bridge
  (`use framework "Foundation"`) with `NSArray`'s `sortedArrayUsingSelector:`.
- Building a long list with `set end of xs to ...` is fast; `set xs to xs & {v}` copies
  the list every time.
- Records cannot be iterated or given keys at run time. For dynamic keys use JXA objects.

## Control flow

```applescript
if n > 10 then
    set label to "big"
else if n > 0 then
    set label to "small"
else
    set label to "none"
end if

repeat 3 times
end repeat
repeat with i from 1 to 10 by 2
end repeat
repeat with x in someList
end repeat
repeat while busy
end repeat
repeat until done
end repeat
repeat
    if found then exit repeat
end repeat
```

`exit repeat` leaves the innermost loop. There is no `continue`; nest an `if` or wrap the
body in `repeat 1 times ... end repeat` and `exit repeat` from it.

## Handlers

```applescript
on greet(personName)
    return "Hello, " & personName
end greet

on joinList(xs, separator)
    set saved to AppleScript's text item delimiters
    set AppleScript's text item delimiters to separator
    set joined to xs as text
    set AppleScript's text item delimiters to saved
    return joined
end joinList

greet("Ann")
```

- Positional parameters in parentheses are the usual form. Labeled parameters
  (`on findItems given folderPath:p`) also exist.
- Handlers can return lists or records: `return {total, average}` and unpack with
  `set {t, a} to summarize(xs)`.
- Call handlers from inside `tell` blocks with `my handlerName(...)` or
  `handlerName(...) of me`.

## Talking to apps: tell blocks

```applescript
tell application "Finder"
    set names to name of every file of desktop
end tell

tell application id "com.apple.mail" -- by bundle id: stable across renames
    count of messages of inbox
end tell
```

- `tell application "X"` launches the app if it is not running. To avoid that, check first:
  `if application "Mail" is running then ...`.
- Terms inside a `tell` block come from that app's dictionary, which is loaded when the
  script compiles. If compilation fails with "Expected end of line" on an app term, the
  term is misspelled, belongs to another app, or the app is missing.
- `tell application "System Events"` is for processes, UI scripting, property list files,
  login items, appearance and disk/folder items. See "System Events vs app scripting"
  in recipes.
- Every app a script talks to must be declared in the manifest's `permissions` as
  `automation:<bundle id>`; the runner refuses undeclared targets.
- `using terms from application "Mail"` lets a script compile against one app's terms
  while addressing another reference.

## Object specifiers and filters

```applescript
tell application "Finder"
    first file of desktop whose name ends with ".pdf"
    every file of folder "Downloads" of home whose modification date > ((current date) - 1 * days)
    name of every window
    item 1 of (get selection)
    files 1 thru 3 of desktop
    some file of desktop          -- a random element
    count of (every item of trash)
end tell
```

- `whose` (or `where`) filters run inside the app and are much faster than looping.
  Supported tests: `is`, `is not`, `contains`, `starts with`, `ends with`, `>`, `<`,
  combined with `and`/`or`.
- `every X of Y` returns a list; `name of every X of Y` returns a list of names in one
  Apple Event. Prefer these bulk forms over loops that send one event per element.
- `get` resolves a reference immediately: `set sel to (get selection)`.
- Elements can be addressed by index (`window 1`), name (`folder "Docs"`),
  id (`message id 123`), range (`items 1 thru 5`), relative position (`front window`,
  `last item`), or test (`whose`).
- Many apps' `id` properties are stable across runs, names are not unique.

## Errors and timeouts

```applescript
try
    tell application "Mail" to set n to count of messages of inbox
on error errorMessage number errorNumber
    if errorNumber is -1743 then
        error "Allow Automation for Mail in System Settings." number errorNumber
    end if
    return "failed: " & errorMessage
end try

error "Nothing selected." number 1001   -- raise your own error

with timeout of 300 seconds
    tell application "Photos" to import ...
end timeout
```

- `error number -128` is "User canceled" (for example Cancel in `display dialog`).
- The default Apple Event timeout is 2 minutes; long commands need `with timeout`.
  The step's own `timeout` still applies, so raise both.
- `ignoring application responses ... end ignoring` sends events without waiting for a reply.
- See permissions-and-errors for the meaning of common error numbers.

## Coercion and comparison

```applescript
"12" as integer          -- 12
"3.5" as real            -- 3.5 (uses the user's decimal separator: prefer integers)
12 as text               -- "12"
{1, 2} as text           -- "12" with empty delimiters
"abc" as list            -- {"a", "b", "c"}
(current date) as text   -- locale-dependent: format dates yourself
class of 5               -- integer
```

- `considering case`, `ignoring white space`, `ignoring punctuation`, `considering numeric strings`
  ("1.10" > "1.9") change how text is compared inside the block.
- Comparing a list item from `repeat with x in xs` needs `contents of x`, because `x` is a
  reference: `if contents of x is "b" then`.

## Standard Additions

Standard Additions are commands available in every script, from
`/System/Library/ScriptingAdditions/StandardAdditions.osax` (introspect "Standard Additions").

| Command | Use |
| --- | --- |
| `display notification "text" with title "T" subtitle "S"` | banner notification (attributed to the running process) |
| `display dialog "Q?" buttons {"No", "Yes"} default button "Yes" default answer ""` | prompt; returns `button returned` and `text returned` |
| `display alert "Title" message "Body" as critical` | alert |
| `choose from list {"a", "b"} with prompt "Pick"` | returns a list, or `false` if cancelled |
| `choose file`, `choose folder` | return an alias |
| `do shell script "cmd"` | runs `/bin/sh -c`; returns stdout; non-zero exit raises an error |
| `path to desktop folder`, `path to home folder`, `path to documents folder` | aliases to standard folders |
| `current date` | now, as a date |
| `delay 0.5` | wait in seconds |
| `the clipboard`, `set the clipboard to "x"` | clipboard text |
| `read`, `write`, `open for access`, `close access` | file I/O (see recipes) |
| `say "text"` | speech |
| `random number from 1 to 10` | random |
| `system info` | record with computer name, user name, OS version |
| `open location "https://..."` | open a URL |

Dialogs block the run until answered, and an automation triggered by a hotkey usually
should not ask questions. Prefer notifications for feedback. Call Standard Additions
outside `tell application` blocks, or wrap them in `tell me`/`tell current application`, to
avoid error -10004 (privilege violation) from the target app.

## AppleScriptObjC in scripts

A script can call Cocoa directly, which helps for regular expressions, JSON and sorting:

```applescript
use AppleScript version "2.7"
use framework "Foundation"
use scripting additions

set s to current application's NSString's stringWithString:"a,b,c"
set parts to (s's componentsSeparatedByString:",") as list   -- {"a", "b", "c"}
```

- With `use framework`, add `use scripting additions` or Standard Additions commands stop
  compiling.
- Convert results back with `as text`, `as list`, `as record`, `as integer`.
- Cocoa objects cannot be returned from the run handler; coerce them first.
