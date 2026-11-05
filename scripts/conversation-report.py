#!/usr/bin/env python3
"""Summarize Automation Agent conversation logs.

Reads the JSON Lines logs the app writes, one file per conversation, in
~/Library/Application Support/AutomationAgent/conversations/ (or the files and folders given
as arguments), and prints one row per conversation: the first request, model, API requests,
tool calls and which tools, approvals and declines, whether an install succeeded (and which
automation), what the user answered on the test card, why the agent loop stopped, tokens,
estimated cost and duration. Then totals.

    scripts/conversation-report.py                     # every log, markdown
    scripts/conversation-report.py path/to/log.jsonl   # one log
    scripts/conversation-report.py --json DIR          # machine-readable

Record shapes follow Shared/Sources/AgentCore/ConversationLog.swift and
App/Sources/ChatController.swift. Standard library only; runs on the stock macOS python3.
"""

import argparse
import json
import os
import sys
from collections import Counter
from datetime import datetime

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/AutomationAgent/conversations")

# US dollars per million tokens, as in Shared/Sources/AgentCore/Pricing.swift. Only used when a
# response line has no costUSD. Unknown models are priced as Opus 5.5 so estimates err high.
PRICING = {
    "claude-opus-5-5": {"input": 4.0, "output": 20.0, "cache_read": 0.20},
    "claude-sonnet-5-5": {"input": 2.0, "output": 10.0, "cache_read": 0.20},
}
DEFAULT_MODEL = "claude-opus-5-5"


def estimate_cost(model, usage):
    """Cost in USD of one response's usage; cache writes cost 1.25x input."""
    price = PRICING.get(model or "", PRICING[DEFAULT_MODEL])
    total = (
        usage.get("input_tokens", 0) * price["input"]
        + usage.get("output_tokens", 0) * price["output"]
        + usage.get("cache_read_input_tokens", 0) * price["cache_read"]
        + usage.get("cache_creation_input_tokens", 0) * price["input"] * 1.25
    )
    return total / 1_000_000


def parse_time(text):
    """The log's ISO 8601 time (UTC, fractional seconds, trailing Z), or None."""
    if not isinstance(text, str) or not text:
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def read_records(path):
    """The JSON objects in a JSON Lines file, and how many lines could not be read."""
    records = []
    bad = 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if isinstance(record, dict):
                records.append(record)
            else:
                bad += 1
    return records, bad


def summarize(path, records, bad_lines=0):
    """One conversation's summary as a plain dict."""
    summary = {
        "file": os.path.basename(path),
        "conversation_id": None,
        "app_version": None,
        "request": None,
        "user_messages": 0,
        "model": None,
        "response_models": [],
        "api_requests": 0,
        "responses": 0,
        "failed_responses": 0,
        "tool_rounds": 0,
        "tool_calls": 0,
        "tool_errors": 0,
        "tools": {},
        "cards": 0,
        "approved": 0,
        "declined": 0,
        "cancelled": 0,
        "snippets_run": 0,
        "install_requests": 0,
        "installed": False,
        "installed_id": None,
        "install_message": None,
        "test_answers": [],
        "stop_reasons": [],
        "stop_reason": None,
        "user_stopped": 0,
        "tokens": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": 0},
        "cost_usd": 0.0,
        "duration_seconds": None,
        "started": None,
        "bad_lines": bad_lines,
    }
    tools = Counter()
    cards = {}  # card id -> request dict, to match answers with what was asked
    first_time = None
    last_time = None

    for record in sorted(records, key=lambda r: r.get("seq", 0) if isinstance(r.get("seq"), int) else 0):
        kind = record.get("type")
        moment = parse_time(record.get("time"))
        if moment is not None:
            first_time = moment if first_time is None or moment < first_time else first_time
            last_time = moment if last_time is None or moment > last_time else last_time

        if kind == "conversation_started":
            summary["conversation_id"] = record.get("conversationID")
            summary["app_version"] = record.get("appVersion")
        elif kind == "user_message":
            summary["user_messages"] += 1
            if summary["request"] is None:
                summary["request"] = record.get("text")
        elif kind == "request":
            summary["api_requests"] += 1
            settings = record.get("settings")
            if isinstance(settings, dict) and settings.get("model") and summary["model"] is None:
                summary["model"] = settings.get("model")
        elif kind == "response":
            summary["responses"] += 1
            model = record.get("model")
            if model and model not in summary["response_models"]:
                summary["response_models"].append(model)
            if record.get("stopReason") == "tool_use":
                summary["tool_rounds"] += 1
            usage = record.get("usage") or {}
            tokens = summary["tokens"]
            tokens["input"] += usage.get("input_tokens", 0)
            tokens["output"] += usage.get("output_tokens", 0)
            tokens["cache_read"] += usage.get("cache_read_input_tokens", 0)
            tokens["cache_write"] += usage.get("cache_creation_input_tokens", 0)
            cost = record.get("costUSD")
            if isinstance(cost, (int, float)):
                summary["cost_usd"] += cost
            else:
                summary["cost_usd"] += estimate_cost(model or summary["model"], usage)
        elif kind == "response_failed":
            summary["failed_responses"] += 1
        elif kind == "tool_call":
            summary["tool_calls"] += 1
            tools[record.get("name") or "?"] += 1
        elif kind == "tool_result":
            if record.get("isError"):
                summary["tool_errors"] += 1
            if record.get("name") == "request_install":
                read_install_result(summary, record)
        elif kind == "card_posted":
            summary["cards"] += 1
            request = record.get("request") if isinstance(record.get("request"), dict) else {}
            cards[record.get("cardID")] = request
            if request.get("kind") == "install":
                summary["install_requests"] += 1
        elif kind == "card_resolved":
            read_card_answer(summary, record, cards.get(record.get("cardID"), {}))
        elif kind == "user_stopped":
            summary["user_stopped"] += 1
        elif kind == "stop":
            reason = record.get("reason")
            summary["stop_reasons"].append(reason)
            summary["stop_reason"] = reason

    tokens = summary["tokens"]
    tokens["total"] = tokens["input"] + tokens["output"] + tokens["cache_read"] + tokens["cache_write"]
    if summary["model"] is None and summary["response_models"]:
        summary["model"] = summary["response_models"][0]
    summary["tools"] = dict(sorted(tools.items(), key=lambda item: (-item[1], item[0])))
    summary["cost_usd"] = round(summary["cost_usd"], 6)
    if first_time is not None and last_time is not None:
        summary["started"] = first_time.isoformat()
        summary["duration_seconds"] = round((last_time - first_time).total_seconds(), 3)
    return summary


def read_install_result(summary, record):
    """request_install's output starts with 'Installed "<id>": ...' on success
    (App/Sources/ToolFormatting.swift); anything else is a refusal, decline or error."""
    output = record.get("output") or ""
    first_line = output.split("\n", 1)[0]
    if not record.get("isError") and first_line.startswith('Installed "'):
        rest = first_line[len('Installed "'):]
        summary["installed"] = True
        summary["installed_id"] = rest.split('"', 1)[0]
        summary["install_message"] = first_line
    elif not summary["installed"]:
        summary["install_message"] = first_line


def read_card_answer(summary, record, request):
    answer = record.get("answer")
    card_kind = request.get("kind")
    if answer == "approved":
        summary["approved"] += 1
        if card_kind == "run_snippet":
            summary["snippets_run"] += 1
    elif answer == "declined":
        summary["declined"] += 1
    elif answer == "cancelled":
        summary["cancelled"] += 1
    elif answer == "answered" and card_kind == "question" and request.get("questionKind") == "test":
        # The test card's buttons answer "Works." or "Didn't work.", plus any notes.
        summary["test_answers"].append(record.get("text") or "")


def test_verdict(answers):
    if not answers:
        return ""
    last = answers[-1].strip().lower()
    if last.startswith("works"):
        return "works"
    if last.startswith("didn't work") or last.startswith("didn\u2019t work"):
        return "didn't work"
    return "answered"


def find_logs(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                if name.endswith(".jsonl"):
                    files.append(os.path.join(path, name))
        elif os.path.isfile(path):
            files.append(path)
        else:
            print("conversation-report: no such file or folder: %s" % path, file=sys.stderr)
    return files


def totals(summaries):
    result = {
        "conversations": len(summaries),
        "installed": sum(1 for s in summaries if s["installed"]),
        "works": sum(1 for s in summaries if test_verdict(s["test_answers"]) == "works"),
        "api_requests": sum(s["api_requests"] for s in summaries),
        "tool_calls": sum(s["tool_calls"] for s in summaries),
        "approved": sum(s["approved"] for s in summaries),
        "declined": sum(s["declined"] for s in summaries),
        "tokens": sum(s["tokens"]["total"] for s in summaries),
        "cost_usd": round(sum(s["cost_usd"] for s in summaries), 6),
        "duration_seconds": round(sum(s["duration_seconds"] or 0 for s in summaries), 3),
        "tools": {},
    }
    tools = Counter()
    for s in summaries:
        tools.update(s["tools"])
    result["tools"] = dict(sorted(tools.items(), key=lambda item: (-item[1], item[0])))
    return result


def cell(text, limit=None):
    """Text safe for one markdown table cell."""
    text = "" if text is None else str(text)
    text = " ".join(text.split())
    if limit is not None and len(text) > limit:
        text = text[: limit - 1].rstrip() + "\u2026"
    return text.replace("|", "\\|")


def duration_text(seconds):
    if seconds is None:
        return ""
    seconds = int(round(seconds))
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm %02ds" % (seconds // 60, seconds % 60)
    return "%dh %02dm" % (seconds // 3600, seconds % 3600 // 60)


def tools_text(tools):
    return ", ".join(name if count == 1 else "%s \u00d7%d" % (name, count) for name, count in tools.items())


def markdown(summaries):
    lines = [
        "| Log | Request | Model | API req. | Tool calls | Tools | Approved / declined | Installed "
        "| Test | Stop | Tokens | Cost | Duration |",
        "| --- | --- | --- | ---: | ---: | --- | --- | --- | --- | --- | ---: | ---: | ---: |",
    ]
    for s in summaries:
        installed = s["installed_id"] if s["installed"] else ("no" if s["install_requests"] else "")
        lines.append("| " + " | ".join([
            cell(s["file"]),
            cell(s["request"], 80),
            cell(s["model"]),
            str(s["api_requests"]),
            str(s["tool_calls"]) + (" (%d err)" % s["tool_errors"] if s["tool_errors"] else ""),
            cell(tools_text(s["tools"])),
            "%d / %d" % (s["approved"], s["declined"]),
            cell(installed),
            cell(test_verdict(s["test_answers"])),
            cell(s["stop_reason"]),
            "{:,}".format(s["tokens"]["total"]),
            "$%.2f" % s["cost_usd"],
            duration_text(s["duration_seconds"]),
        ]) + " |")
    t = totals(summaries)
    lines += [
        "",
        "**Totals:** %d conversation(s), %d installed, %d tested as working; %d API requests, "
        "%d tool calls, %d approved / %d declined; %s tokens, $%.2f, %s."
        % (t["conversations"], t["installed"], t["works"], t["api_requests"], t["tool_calls"],
           t["approved"], t["declined"], "{:,}".format(t["tokens"]), t["cost_usd"],
           duration_text(t["duration_seconds"])),
    ]
    if t["tools"]:
        lines.append("")
        lines.append("**Tools:** " + tools_text(t["tools"]) + ".")
    bad = sum(s["bad_lines"] for s in summaries)
    if bad:
        lines.append("")
        lines.append("%d unreadable line(s) skipped." % bad)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Summarize Automation Agent conversation logs.")
    parser.add_argument("paths", nargs="*", help="log files or folders (default: %s)" % DEFAULT_DIR)
    parser.add_argument("--json", action="store_true", help="print JSON instead of a markdown table")
    args = parser.parse_args(argv)

    files = find_logs(args.paths or [DEFAULT_DIR])
    summaries = []
    for path in files:
        try:
            records, bad = read_records(path)
        except OSError as error:
            print("conversation-report: cannot read %s: %s" % (path, error), file=sys.stderr)
            continue
        if records:
            summaries.append(summarize(path, records, bad))

    if args.json:
        json.dump({"conversations": summaries, "totals": totals(summaries)}, sys.stdout, indent=2,
                  ensure_ascii=False)
        sys.stdout.write("\n")
    elif not summaries:
        print("No conversation logs found.")
    else:
        print(markdown(summaries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
