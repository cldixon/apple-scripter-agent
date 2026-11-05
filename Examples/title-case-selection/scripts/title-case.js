// Step 1 of title-case-selection.
// Input: {"selection": "<the selected text>"}. Output: the text in Title Case.
// Pure text in, text out: no Apple Events, so it can be tested with fixed inputs.
//
// Rules (close to common headline styles):
// - Every word is capitalized except small words (articles, short conjunctions and
//   prepositions), which stay lowercase unless they start or end a line or follow : ? ! .
//   or a dash.
// - Words with capitals after their first letter (iPhone, NASA, McDonald) are kept as
//   they are, unless the whole text is in capitals, which is lowercased first.
// - Words containing . / @ _ or \ (file names, URLs, e-mail addresses) are kept as they are.
// - Each part of a hyphenated word is handled like a word (Self-Driving, Out-of-Date).
// - Spacing and line breaks are kept exactly; each line is titled on its own.
const SMALL_WORDS = new Set([
    "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
    "as", "at", "by", "in", "of", "off", "on", "per", "to", "up", "via", "vs", "v"
]);

function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    return titleCase(String(input.selection || ""));
}

function titleCase(text) {
    const shouting = /\p{Lu}/u.test(text) && !/\p{Ll}/u.test(text);
    const source = shouting ? text.toLowerCase() : text;
    return source.split(/(\r\n|\r|\n)/).map(line => (/^(\r\n|\r|\n)$/.test(line) ? line : titleLine(line))).join("");
}

function titleLine(line) {
    const tokens = line.split(/(\s+)/);
    const wordIndexes = [];
    tokens.forEach((token, i) => {
        if (token && !/^\s+$/.test(token)) wordIndexes.push(i);
    });
    let startsPhrase = true;
    wordIndexes.forEach((tokenIndex, n) => {
        const isLast = n === wordIndexes.length - 1;
        const token = tokens[tokenIndex];
        tokens[tokenIndex] = titleWord(token, startsPhrase || isLast);
        startsPhrase = /[:?!.\u2014\u2013]$/.test(token) || /^[\u2014\u2013-]+$/.test(token);
    });
    return tokens.join("");
}

// One whitespace-free token, which may carry punctuation such as "(word)," around it.
function titleWord(token, force) {
    const match = /^([^\p{L}\p{N}]*)(.*?)([^\p{L}\p{N}]*)$/u.exec(token);
    const [, before, core, after] = match;
    if (!core) return token;
    if (/[./@_\\]/.test(core)) return token;
    if (/^.+\p{Lu}/u.test(core)) return token;
    const parts = core.split("-");
    const titled = parts.map((part, i) => {
        const lower = part.toLowerCase();
        const edge = force && (i === 0 || i === parts.length - 1);
        if (!edge && SMALL_WORDS.has(lower) && (i > 0 || !force)) return lower;
        return capitalize(part);
    });
    return before + titled.join("-") + after;
}

// Uppercases the first letter (skipping leading digits or apostrophes inside the core).
function capitalize(word) {
    return word.replace(/\p{L}/u, letter => letter.toUpperCase());
}
