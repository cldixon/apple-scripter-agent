# Text transform recipes

Transforming text between steps: trimming, removing blank lines, changing case and title
case, in JXA, AppleScript and zsh. Prefer JXA for anything with patterns: it has regular
expressions, Unicode-aware case mapping and JSON input. Keep transforms in their own step
(text in, text out, no Apple Events) so they can be tested with fixed inputs.

## Trim lines and remove blank lines

JXA (recommended). `\s` covers spaces, tabs, no-break spaces and the BOM; add `\u200B`
(zero-width space) when pasting from web pages.

```javascript
function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    return String(input.clip || "")
        .split(/\r\n|[\r\n\u2028\u2029]/)
        .map(line => line.replace(/^[\s\u200B]+|[\s\u200B]+$/g, ""))   // trim each line
        .filter(line => line.length > 0)                                  // drop blank lines
        .join("\n");
}
```

Variants:
- Keep indentation: trim only the end of each line, `line.replace(/[\s\u200B]+$/, "")`,
  then trim the whole result's leading blank lines.
- Collapse runs of spaces inside a line: `.replace(/[ \t\u00A0]+/g, " ")`.
- Keep paragraph breaks but squeeze several blank lines into one:
  `text.replace(/\n[ \t]*(\n[ \t]*)+/g, "\n\n").trim()`.

zsh: read the value from `$AUTOMATION_VAR_<name>`, never by splicing it into code.

```zsh
#!/bin/zsh
text=${AUTOMATION_VAR_clip-}
# Trim every line and drop blank lines (sed -E works the same with BSD and GNU sed).
print -r -- "$text" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
```

`grep -v '^$'` exits 1 when every line was blank; add `|| true` if that must not fail the
step. `[[:space:]]` does not match a no-break space in the C locale; use JXA when the text
comes from web pages or word processors.

AppleScript has no regular expressions. Trim with the `trimText` handler in recipes
("Trimming and cleaning text") and remove blank lines with `paragraphs of`:

```applescript
set kept to {}
repeat with p in paragraphs of theText
    set p to my trimText(contents of p)
    if p is not "" then set end of kept to p
end repeat
set AppleScript's text item delimiters to linefeed
set cleaned to kept as text
set AppleScript's text item delimiters to ""
```

## Upper, lower and sentence case

| Where | Upper | Lower |
| --- | --- | --- |
| JXA | `s.toUpperCase()` | `s.toLowerCase()` |
| AppleScriptObjC | `((current application's NSString's stringWithString:s)'s uppercaseString()) as text` | `lowercaseString()` |
| zsh | `${(U)s}` | `${(L)s}` |
| awk / tr | `toupper(s)`, `tr '[:lower:]' '[:upper:]'` | `tolower(s)` |

- JXA and NSString handle accented letters (é → É, ß → SS in upper case).
- zsh's `(U)`/`(L)` flags follow the locale; a step started by the runner may not run
  in a UTF-8 locale, so non-ASCII letters may be left unchanged. `tr` and `awk` on macOS
  are byte-oriented in the C locale. Use JXA when the text may contain non-ASCII letters.
- NSString also has `capitalizedString()`, which capitalizes *every* word ("Of The"),
  so it is not title case.
- Sentence case in JXA: `s.toLowerCase().replace(/(^\s*|[.!?]\s+)(\p{L})/gu, (m, a, b) => a + b.toUpperCase())`.

## Title case with small words

Headline title case capitalizes every word except small words (articles, short
conjunctions and prepositions), which stay lowercase unless they are the first or last
word or follow a colon. Rules worth keeping:

- Leave words with capitals after the first letter alone (iPhone, NASA, McDonald), unless
  the whole text is in capitals: then lowercase it first.
- Leave words containing `.`, `/`, `@`, `_` alone: file names, URLs, e-mail addresses.
- Treat each part of a hyphenated word as a word (Self-Driving, State-of-the-Art).
- Keep the original spacing and line breaks; title each line on its own.

```javascript
const SMALL = new Set(["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
    "as", "at", "by", "in", "of", "off", "on", "per", "to", "up", "via", "vs"]);

function titleLine(line) {
    const tokens = line.split(/(\s+)/);
    const words = tokens.map((t, i) => i).filter(i => tokens[i] && !/^\s+$/.test(tokens[i]));
    let startsPhrase = true;
    words.forEach((i, n) => {
        const token = tokens[i];
        const force = startsPhrase || n === words.length - 1;
        const [, pre, core, post] = /^([^\p{L}\p{N}]*)(.*?)([^\p{L}\p{N}]*)$/u.exec(token);
        if (core && !/[./@_\\]/.test(core) && !/^.+\p{Lu}/u.test(core)) {
            const parts = core.split("-");
            tokens[i] = pre + parts.map((part, k) => {
                const lower = part.toLowerCase();
                const edge = force && (k === 0 || k === parts.length - 1);
                return !edge && SMALL.has(lower) ? lower : part.replace(/\p{L}/u, c => c.toUpperCase());
            }).join("-") + post;
        }
        startsPhrase = /[:?!.\u2014\u2013]$/.test(token);
    });
    return tokens.join("");
}
```

The complete version, with the all-capitals rule and tests, is
`Examples/title-case-selection/scripts/title-case.js`. Style guides disagree on details
(AP capitalizes prepositions of four letters or more; Chicago lowercases all
prepositions); tell the user which rule you chose if they care.

AppleScript has no clean way to do this; call a JXA step instead. In zsh, an `awk`
version is possible but byte-oriented, so it mishandles accented first letters.

## Passing text between steps safely

- Script steps receive earlier outputs as JSON (AppleScript `item 1 of argv`, JXA
  `JSON.parse(argv[0])`) and shell steps also as `$AUTOMATION_VAR_<name>`. All values are
  strings.
- In zsh use `print -r -- "$text"`, never `echo`: zsh's `echo` interprets backslash
  escapes, so `C:\new` would print a line break.
- Never build AppleScript or shell source from user text. In AppleScript use
  `quoted form of` for `do shell script`; in zsh quote every expansion (`"$text"`).
- The runner removes one trailing newline from a step's output; a JXA `return` adds none,
  `print` adds one.
- `pbcopy` and `pbpaste` pick the text encoding from the locale. A step started by the runner
  may not have a UTF-8 locale; if non-ASCII text comes out garbled, run them as
  `LC_ALL=en_US.UTF-8 pbpaste`. The `readClipboard`/`writeClipboard` primitives and JXA
  `setTheClipboardTo` avoid the issue.
- A transform that may produce an empty result should say what to do with it: pasting or
  copying "" is rarely what the user wants (see "Copy only when there is something" in
  recipes-apps).
