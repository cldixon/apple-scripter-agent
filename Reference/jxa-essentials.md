# JXA essentials

JavaScript for Automation (JXA) is JavaScript with Apple Event bridging, run by
`osascript -l JavaScript`. Use it when a step needs JSON, objects with dynamic keys,
regular expressions or real data structures; use AppleScript when an app's dictionary
works poorly from JXA (some apps' `make` and `whose` forms are more reliable in AppleScript).

## How JXA steps run here

```javascript
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");   // every named output so far
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    const text = input.clip || app.theClipboard();
    return text.toUpperCase();                    // becomes the step's output
}
```

- `argv[0]` is a JSON object string of the named outputs (`"as"` names in the manifest).
- The return value of `run` is the output. Return a string; objects and arrays are printed
  in a non-JSON form, so `return JSON.stringify(value)` when the next step needs structure.
- `console.log(...)` writes to stderr, which is shown on failure but is not the output.
- Uncaught exceptions fail the step with their message.
- Top-level code outside `run` also executes; keep everything in functions.

## Application objects

```javascript
const finder = Application("Finder");             // by name
const mail = Application("com.apple.mail");       // by bundle id
const me = Application.currentApplication();      // the running osascript (for Standard Additions)
me.includeStandardAdditions = true;

finder.running();            // true if running; does not launch
mail.activate();             // bring to front (launches if needed)
const sysEvents = Application("System Events");
```

- Addressing an app object does not launch it, but reading a property or sending a command
  does. Check `app.running()` first when launching would be surprising.
- Standard Additions commands (`displayNotification`, `doShellScript`, `theClipboard`,
  `setTheClipboardTo`, `displayDialog`, `pathTo`, `say`, `delay`) need
  `includeStandardAdditions = true` on the object you call them on. Calling them on
  `Application.currentApplication()` avoids privilege errors (-10004) from other apps.
- `delay(seconds)` is a global function.

## Properties, elements and commands

Properties are functions: call them to read, assign to write.

```javascript
const finder = Application("Finder");
finder.name();                              // "Finder"
const win = finder.windows[0];              // a specifier, nothing sent yet
win.name();                                 // reads the property (one Apple Event)
win.bounds = {x: 0, y: 25, width: 800, height: 600};   // sets it

finder.windows.length;                      // count
finder.windows.name();                      // array of all window names, one event
finder.desktop.files.byName("notes.txt");
mail.inbox.messages.byId(12345);
finder.selection();                         // array of specifiers
```

- Element collections support `[index]`, `.byName("x")`, `.byId(n)`, `.length`, `.at(i)`.
- Calling a property on a collection (`app.windows.name()`) returns an array in one event;
  it is much faster than mapping over elements.
- Property and command names are the AppleScript terms in camelCase: `modification date`
  → `modificationDate`, `display notification` → `displayNotification`, `make new` → `make`.
- Command parameters go in an object: `app.displayDialog("Continue?", {buttons: ["No", "Yes"],
  defaultButton: "Yes"})`; the direct parameter comes first.
- A specifier is lazy: `finder.windows[0]` is a reference; `()` sends the event.

## Filtering with whose

```javascript
const notes = Application("Notes");
notes.notes.whose({name: "Groceries"})();
notes.notes.whose({name: {_contains: "meeting"}})();
mail.inbox.messages.whose({readStatus: false}).subject();
finder.desktop.files.whose({nameExtension: "pdf"})();
reminders.reminders.whose({_and: [{completed: false}, {name: {_beginsWith: "Call"}}]})();
```

- Operators: `_equals` (the default), `_contains`, `_beginsWith`, `_endsWith`,
  `_greaterThan`, `_lessThan`, `_greaterThanEquals`, `_lessThanEquals`, combined with
  `_and`, `_or`, `_not`.
- `whose` works only on element collections and runs inside the app (fast). Some apps
  reject certain forms; fall back to reading arrays of properties and filtering in JS.
- Date comparisons: `{modificationDate: {_greaterThan: new Date(Date.now() - 86400000)}}`.

## Creating objects

```javascript
const reminders = Application("Reminders");
const r = reminders.Reminder({name: "Call Ann", dueDate: new Date(Date.now() + 3600e3)});
reminders.defaultList.reminders.push(r);          // creates it

const notes = Application("Notes");
const note = notes.Note({name: "Title", body: "<div>Body</div>"});
notes.defaultAccount.folders.byName("Notes").notes.push(note);

const finder = Application("Finder");
finder.make({new: "folder", at: finder.desktop, withProperties: {name: "Reports"}});
```

- Constructors are the class name capitalized (`Reminder`, `Note`, `Document`, `Event`).
  Push the new object onto the right element collection to create it.
- The `make` command works too: `app.make({new: "document", withProperties: {...}})`.
- After `push`, the JS object refers to the created element.

## Paths and files

```javascript
const p = Path("/Users/me/Desktop/report.pdf");   // file reference for app commands
Application("Finder").open(p);
Application("Preview").open(Path("/tmp/x.png"));
p.toString();                                      // "/Users/me/Desktop/report.pdf"

const me = Application.currentApplication();
me.includeStandardAdditions = true;
me.pathTo("desktop").toString();                   // "/Users/me/Desktop"
```

Finder items convert to paths with `Path(item.url().replace("file://", ""))` or, more
reliably, `decodeURI(item.url()).slice(7)`; for a Finder selection, prefer
`finder.selection().map(i => decodeURI(i.url()).slice(7))`. AppleScript's `POSIX path of
(item as alias)` is often simpler for Finder.

## The Objective-C bridge

```javascript
ObjC.import("Foundation");
const home = ObjC.unwrap($.NSHomeDirectory());
const env = $.NSProcessInfo.processInfo.environment;
const value = ObjC.unwrap(env.objectForKey("HOME"));

// Read a text file
const contents = $.NSString.stringWithContentsOfFileEncodingError(
    "/tmp/in.txt", $.NSUTF8StringEncoding, null);
const text = ObjC.unwrap(contents);   // undefined if the file is missing

// Write a text file
$(text).writeToFileAtomicallyEncodingError("/tmp/out.txt", true, $.NSUTF8StringEncoding, null);

// Files in a folder
const fm = $.NSFileManager.defaultManager;
const names = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError("/tmp", null));
```

- `$("js string")` makes an `NSString`; `ObjC.unwrap` and `ObjC.deepUnwrap` turn Cocoa
  values back into JS values; `.js` is shorthand for `ObjC.unwrap`.
- Selectors drop colons and capitalize the following word:
  `writeToFile:atomically:encoding:error:` → `writeToFileAtomicallyEncodingError`.
- `ObjC.import("AppKit")` gives `$.NSPasteboard`, `$.NSWorkspace`, `$.NSScreen`.
- Pass `null` for `NSError **` parameters, or `$()` to receive the error object.

## Shell commands and Standard Additions from JXA

```javascript
const me = Application.currentApplication();
me.includeStandardAdditions = true;
const out = me.doShellScript("ls -1 " + quoted("/tmp/My Folder"));
me.displayNotification("Done", {withTitle: "Automation"});
me.setTheClipboardTo("copied text");
const clip = me.theClipboard();
me.say("Finished");

function quoted(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
```

`doShellScript` runs `/bin/sh -c` with a minimal PATH and returns stdout with line endings
converted to CR (`\r`); split with `/\r|\n/`, or pass `{alteringLineEndings: false}`.

## Errors and gotchas

```javascript
try {
    Application("Mail").inbox.messages[0].subject();
} catch (e) {
    // e.message, e.errorNumber (e.g. -1728 "Can't get object", -1743 not authorized)
    throw new Error("Could not read Mail: " + e.message);
}
```

- Forgetting `()` returns a specifier, not the value: `win.name` is a function, `win.name()`
  is the text. Comparing specifiers with `===` compares references, not values.
- `app.windows[0]` on an app with no windows throws -1719 or -1728 when read.
- `whose` results are specifiers; call them `(...)()` or read a property to get values.
- Dates cross the bridge as JS `Date` objects; format them with `toISOString()` or the
  helpers in recipes.
- Integers above 2^31 and some enumerations come back as strings or numbers depending on
  the app; check with `typeof` while exploring (run_snippet).
- `Application("Name")` with a misspelled or missing app throws "Application can't be found."
- Use `JSON.stringify` for anything structured you return.
