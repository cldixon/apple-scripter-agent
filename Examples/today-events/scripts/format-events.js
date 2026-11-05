// Step 1 of today-events.
// Input: {"events": "<step 0's tab-separated lines>"} (see read-events.applescript).
// Output: one line per event still to come today (or in progress), all-day events first:
//   All day: Holiday
//   Ongoing: Conference          (started before today)
//   14:00 Weekly sync
// or "No more events today." Pure text in, text out, so it can be tested with fixed inputs:
// "now" comes from the input, not the clock.
//
// Repeating events are expanded here from their RRULE (RFC 5545): FREQ DAILY, WEEKLY,
// MONTHLY and YEARLY with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY and BYMONTH, minus
// excluded dates. Other rules are listed as "not checked" rather than guessed.

const WEEKDAYS = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
const DAY_MS = 86400000;

function run(argv) {
    const input = JSON.parse(argv[0] || "{}");
    let now = null;
    const events = [];
    for (const line of String(input.events || "").split("\n")) {
        const f = line.split("\t");
        if (f[0] === "now") {
            now = parseLocal(f[1]);
        } else if (f[0] === "event" && f.length >= 6) {
            events.push({
                title: f[2] || "(No title)",
                start: parseLocal(f[3]),
                end: parseLocal(f[4]),
                allDay: f[5] === "true",
                rule: (f[6] || "").trim(),
                excluded: (f[7] || "").split(",").filter(Boolean).map(parseLocal).filter(Boolean)
            });
        }
    }
    if (!now) now = new Date();
    const dayStart = startOfDay(now);
    const dayEnd = addDays(dayStart, 1);

    const items = [];
    const unchecked = [];
    for (const ev of events) {
        if (!ev.start || !ev.end) continue;
        let occurrence = { start: ev.start, end: ev.end };
        if (ev.rule) {
            let found;
            try {
                found = occurrenceOn(ev, dayStart);
            } catch (error) {
                unchecked.push(ev.title);
                continue;
            }
            if (!found) continue;
            occurrence = found;
        }
        if (!(occurrence.start < dayEnd && occurrence.end > dayStart)) continue;
        if (ev.allDay) {
            items.push({ order: 0, time: 0, text: "All day: " + ev.title });
        } else if (occurrence.end > now) {
            const ongoing = occurrence.start < dayStart;
            items.push({
                order: 1,
                time: occurrence.start.getTime(),
                text: ongoing ? "Ongoing: " + ev.title : hhmm(occurrence.start) + " " + ev.title
            });
        }
    }

    const seen = {};
    const lines = items
        .sort((a, b) => a.order - b.order || a.time - b.time || (a.text < b.text ? -1 : a.text > b.text ? 1 : 0))
        .map(item => item.text)
        .filter(text => (seen[text] ? false : (seen[text] = true)));
    if (unchecked.length > 0) {
        lines.push("Not checked (unsupported repeat rule): " + unchecked.join(", "));
    }
    return lines.length > 0 ? lines.join("\n") : "No more events today.";
}

// The occurrence of a repeating event on `day` ({start, end}), or null. Throws for rules
// this function does not understand.
function occurrenceOn(ev, day) {
    const rule = parseRule(ev.rule);
    const freq = rule.FREQ;
    if (!["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(freq)) throw new Error("FREQ " + freq);
    for (const part of ["BYSETPOS", "BYYEARDAY", "BYWEEKNO", "BYHOUR", "BYMINUTE", "BYSECOND", "RDATE"]) {
        if (rule[part]) throw new Error(part);
    }
    const interval = parseInt(rule.INTERVAL || "1", 10) || 1;
    const count = rule.COUNT ? parseInt(rule.COUNT, 10) : null;
    const until = rule.UNTIL ? parseUntil(rule.UNTIL) : null;
    const first = startOfDay(ev.start);
    if (day < first) return null;

    const occurrenceStart = d => new Date(d.getFullYear(), d.getMonth(), d.getDate(),
        ev.start.getHours(), ev.start.getMinutes(), ev.start.getSeconds());

    if (count === null) {
        if (!matches(rule, freq, interval, ev.start, day)) return null;
    } else {
        // COUNT limits the number of occurrences: count them from the first one.
        let n = 0;
        let reached = false;
        for (let d = first, steps = 0; d <= day; d = addDays(d, 1), steps++) {
            if (steps > 50000) throw new Error("too far back");
            if (!matches(rule, freq, interval, ev.start, d)) continue;
            n++;
            if (n > count) return null;
            if (d.getTime() === day.getTime()) reached = true;
        }
        if (!reached) return null;
    }
    const start = occurrenceStart(day);
    if (until && start > until) return null;
    if (ev.excluded.some(x => sameDay(x, day))) return null;
    return { start: start, end: new Date(start.getTime() + (ev.end - ev.start)) };
}

function matches(rule, freq, interval, seriesStart, d) {
    const first = startOfDay(seriesStart);
    const months = list(rule.BYMONTH).map(Number);
    if (months.length > 0 && !months.includes(d.getMonth() + 1)) return false;
    const byDay = list(rule.BYDAY);
    const monthDays = list(rule.BYMONTHDAY).map(Number);

    if (freq === "DAILY") {
        if (daysBetween(first, d) % interval !== 0) return false;
        return byDay.length === 0 || byDay.some(entry => weekdayMatches(entry, d, false));
    }
    if (freq === "WEEKLY") {
        const weekStart = WEEKDAYS[rule.WKST || "MO"];
        const weeks = Math.floor(daysBetween(startOfWeek(first, weekStart), startOfWeek(d, weekStart)) / 7);
        if (weeks % interval !== 0) return false;
        if (byDay.length === 0) return d.getDay() === seriesStart.getDay();
        return byDay.some(entry => weekdayMatches(entry, d, false));
    }
    if (freq === "MONTHLY") {
        const monthsApart = (d.getFullYear() - first.getFullYear()) * 12 + d.getMonth() - first.getMonth();
        if (monthsApart % interval !== 0) return false;
        if (monthDays.length > 0) return monthDays.some(n => monthDayMatches(n, d));
        if (byDay.length > 0) return byDay.some(entry => weekdayMatches(entry, d, true));
        return d.getDate() === seriesStart.getDate();
    }
    // YEARLY
    if ((d.getFullYear() - first.getFullYear()) % interval !== 0) return false;
    if (months.length === 0 && d.getMonth() !== seriesStart.getMonth()) return false;
    if (monthDays.length > 0) return monthDays.some(n => monthDayMatches(n, d));
    if (byDay.length > 0) {
        if (months.length === 0) throw new Error("yearly BYDAY without BYMONTH");
        return byDay.some(entry => weekdayMatches(entry, d, true));
    }
    return d.getDate() === seriesStart.getDate();
}

// "TH", "2TH" (second Thursday of the month), "-1FR" (last Friday of the month).
function weekdayMatches(entry, d, ordinalInMonth) {
    const match = /^([+-]?\d{1,2})?([A-Z]{2})$/.exec(entry);
    if (!match || !(match[2] in WEEKDAYS)) throw new Error("BYDAY " + entry);
    if (WEEKDAYS[match[2]] !== d.getDay()) return false;
    if (!match[1]) return true;
    if (!ordinalInMonth) throw new Error("ordinal BYDAY " + entry);
    const n = parseInt(match[1], 10);
    if (n > 0) return Math.ceil(d.getDate() / 7) === n;
    return Math.floor((daysInMonth(d) - d.getDate()) / 7) + 1 === -n;
}

function monthDayMatches(n, d) {
    return n > 0 ? d.getDate() === n : d.getDate() === daysInMonth(d) + n + 1;
}

function parseRule(text) {
    const rule = {};
    for (const part of text.replace(/^RRULE:/i, "").split(";")) {
        const [key, value] = part.split("=");
        if (key && value !== undefined) rule[key.trim().toUpperCase()] = value.trim().toUpperCase();
    }
    return rule;
}

function list(value) {
    return value ? value.split(",").filter(Boolean) : [];
}

// "yyyy-MM-ddTHH:mm:ss" in local time.
function parseLocal(text) {
    const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/.exec(String(text || "").trim());
    if (!m) return null;
    return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
}

// RRULE UNTIL: 20261231T225959Z (UTC), 20261231T225959 (local) or 20261231 (that whole day).
function parseUntil(text) {
    const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?$/.exec(text);
    if (!m) throw new Error("UNTIL " + text);
    if (!m[4]) return new Date(+m[1], +m[2] - 1, +m[3], 23, 59, 59);
    if (m[7]) return new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]));
    return new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +m[6]);
}

function startOfDay(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function addDays(d, n) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
}

function startOfWeek(d, weekStart) {
    return addDays(startOfDay(d), -((d.getDay() - weekStart + 7) % 7));
}

// Whole calendar days from a to b, unaffected by daylight saving changes.
function daysBetween(a, b) {
    return Math.round((Date.UTC(b.getFullYear(), b.getMonth(), b.getDate())
        - Date.UTC(a.getFullYear(), a.getMonth(), a.getDate())) / DAY_MS);
}

function daysInMonth(d) {
    return new Date(d.getFullYear(), d.getMonth() + 1, 0).getDate();
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

function hhmm(d) {
    return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
}
