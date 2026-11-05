// Step 2 of copy-safari-link.
// Input: {"link": "<step 1's Markdown link or empty>"}.
// Copies the link when there is one and leaves the clipboard alone otherwise.
// Output: the notification text.
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    const link = String(input.link || "");
    if (!link) return "Safari has no open page, so nothing was copied.";
    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    app.setTheClipboardTo(link);
    return "Copied " + link;
}
