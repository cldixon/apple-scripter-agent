// Step 1 of copy-finder-paths.
// Input: {"paths": "<one POSIX path per line, or empty>"}.
// Copies the paths when there are any and leaves the clipboard alone otherwise.
// Output: the notification text.
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    const paths = String(input.paths || "");
    if (!paths) return "Nothing is selected in Finder, so nothing was copied.";
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    app.setTheClipboardTo(paths);
    const count = paths.split("\n").length;
    return count === 1 ? "Copied " + paths : "Copied " + count + " paths";
}
