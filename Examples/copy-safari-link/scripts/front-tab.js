// Step 0 of copy-safari-link.
// Output: JSON {"title": "...", "url": "..."} for Safari's front tab, or {} when Safari is
// not running or has no window showing a page. Never launches Safari.
function run(argv) {
    const safari = Application("Safari");
    if (!safari.running()) return "{}";
    // windows() is in front-to-back order. Some windows (Settings, a download sheet) have
    // no current tab, and an empty new tab has no URL: skip those.
    for (const win of safari.windows()) {
        let url = "";
        let title = "";
        try {
            const tab = win.currentTab();
            url = tab.url() || "";
            title = tab.name() || "";
        } catch (error) {
            continue;
        }
        if (url) return JSON.stringify({ title: title, url: url });
    }
    return "{}";
}
