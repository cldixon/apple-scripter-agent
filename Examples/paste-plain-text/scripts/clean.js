// Step 1 of paste-plain-text.
// Input: {"clip": "<clipboard text>"} (step 0's output).
// Output: the text with every line trimmed at both ends and blank lines removed.
// Pure text in, text out: no Apple Events, so it can be tested with fixed inputs.
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    const text = String(input.clip || "");
    return text
        .split(/\r\n|[\r\n\u2028\u2029]/)
        // \s covers spaces, tabs, no-break spaces and the BOM; add the zero-width space.
        .map(line => line.replace(/^[\s\u200B]+|[\s\u200B]+$/g, ""))
        .filter(line => line.length > 0)
        .join("\n");
}
