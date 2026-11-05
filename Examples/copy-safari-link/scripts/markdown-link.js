// Step 1 of copy-safari-link.
// Input: {"page": "<step 0's JSON: {title, url} or {}>"}.
// Output: a Markdown link [title](url), or "" when there is no page.
// Pure text in, text out: no Apple Events, so it can be tested with fixed inputs.
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    let page = {};
    try {
        page = JSON.parse(input.page || "{}") || {};
    } catch (error) {
        page = {};
    }
    const url = String(page.url || "").trim();
    if (!url) return "";
    // Titles can hold line breaks and runs of spaces; an empty title falls back to the URL.
    const title = String(page.title || "").replace(/\s+/g, " ").trim() || url;
    // Backslashes and square brackets would end or break the link text: escape them.
    const text = title.replace(/[\\\[\]]/g, "\\$&");
    // Spaces and parentheses would end the link destination: percent-encode them.
    const destination = url.replace(/ /g, "%20").replace(/\(/g, "%28").replace(/\)/g, "%29");
    return "[" + text + "](" + destination + ")";
}
