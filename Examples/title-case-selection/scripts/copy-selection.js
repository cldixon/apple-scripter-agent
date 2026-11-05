// Step 0 of title-case-selection: the best this can do before a copySelection primitive.
// Copies the frontmost app's selection with Command-C (System Events) and returns it as
// text, then puts the clipboard's previous text back. Output: the selected text, or ""
// when nothing was copied (no selection, or the app has no Copy).
//
// Caveats (see Examples/README.md):
// - The hotkey fires while Control, Option and Command are still held; a Command-C sent
//   then would arrive as Control-Option-Command-C. So wait (up to 1.5 s) until no modifier
//   is down. NSEvent.modifierFlags reads the current state of the keyboard.
// - Only the clipboard's plain text is restored; images or rich text on it are lost.
function run(argv) {
    ObjC.import("AppKit");
    // NSEventModifierFlag Shift, Control, Option, Command (1 << 17 ... 1 << 20).
    const held = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20);
    for (let i = 0; i < 50 && ($.NSEvent.modifierFlags & held) !== 0; i++) {
        delay(0.03);
    }

    const pasteboard = $.NSPasteboard.generalPasteboard;
    const previous = pasteboard.stringForType($.NSPasteboardTypeString);
    const before = pasteboard.changeCount;
    Application("System Events").keystroke("c", { using: "command down" });

    // The app writes the clipboard asynchronously: wait for its change count to move.
    let copied = false;
    for (let i = 0; i < 40 && !copied; i++) {
        delay(0.025);
        copied = pasteboard.changeCount !== before;
    }
    if (!copied) return "";
    delay(0.05);
    const text = ObjC.unwrap(pasteboard.stringForType($.NSPasteboardTypeString)) || "";

    if (!previous.isNil()) {
        pasteboard.clearContents;
        pasteboard.setStringForType(previous, $.NSPasteboardTypeString);
    }
    return text;
}
