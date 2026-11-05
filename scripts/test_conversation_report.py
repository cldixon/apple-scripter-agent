#!/usr/bin/env python3
"""Tests for conversation-report.py against the synthetic logs in scripts/fixtures/.

Run from the repository root:  python3 -m unittest discover -s scripts -p 'test_*.py'
(CI does not run these; see docs/EVALUATING.md.)
"""

import contextlib
import importlib.util
import io
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
INSTALLED = os.path.join(FIXTURES, "2026-11-05T10-00-00Z-1a2b3c4d.jsonl")
DECLINED = os.path.join(FIXTURES, "2026-11-05T10-30-00Z-5e6f7a8b.jsonl")

_spec = importlib.util.spec_from_file_location("conversation_report", os.path.join(HERE, "conversation-report.py"))
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)


def summary_of(path):
    records, bad = report.read_records(path)
    return report.summarize(path, records, bad)


def run_main(args):
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        status = report.main(args)
    return status, output.getvalue()


class InstalledConversationTests(unittest.TestCase):
    def setUp(self):
        self.summary = summary_of(INSTALLED)

    def test_request_and_model(self):
        self.assertEqual(self.summary["request"], "Make ⌃⌥⌘L toggle between light and dark appearance.")
        self.assertEqual(self.summary["model"], "claude-opus-5-5")
        self.assertEqual(self.summary["conversation_id"], "1A2B3C4D-0000-4000-8000-000000000001")
        self.assertEqual(self.summary["app_version"], "0.2.0")

    def test_counts(self):
        self.assertEqual(self.summary["api_requests"], 7)
        self.assertEqual(self.summary["responses"], 7)
        self.assertEqual(self.summary["tool_rounds"], 6)
        self.assertEqual(self.summary["tool_calls"], 6)
        self.assertEqual(self.summary["tool_errors"], 0)
        self.assertEqual(set(self.summary["tools"]), {
            "search_catalog", "run_snippet", "write_draft", "validate", "request_install", "ask_user"})

    def test_cards(self):
        self.assertEqual(self.summary["cards"], 3)
        self.assertEqual(self.summary["approved"], 2)
        self.assertEqual(self.summary["declined"], 0)
        self.assertEqual(self.summary["snippets_run"], 1)
        self.assertEqual(self.summary["test_answers"], ["Works. Switched both ways."])
        self.assertEqual(report.test_verdict(self.summary["test_answers"]), "works")

    def test_install(self):
        self.assertTrue(self.summary["installed"])
        self.assertEqual(self.summary["installed_id"], "toggle-dark-mode")
        self.assertEqual(self.summary["install_requests"], 1)

    def test_stop_tokens_cost_duration(self):
        self.assertEqual(self.summary["stop_reason"], "completed")
        tokens = self.summary["tokens"]
        self.assertEqual(tokens["input"], 5000)
        self.assertEqual(tokens["output"], 3370)
        self.assertEqual(tokens["cache_read"], 141000)
        self.assertEqual(tokens["cache_write"], 24800)
        self.assertEqual(tokens["total"], 174170)
        # The sum of each response's costUSD.
        self.assertAlmostEqual(self.summary["cost_usd"], 0.2396, places=6)
        self.assertGreater(self.summary["duration_seconds"], 200)

    def test_bad_line_is_skipped(self):
        self.assertEqual(self.summary["bad_lines"], 1)


class DeclinedConversationTests(unittest.TestCase):
    def setUp(self):
        self.summary = summary_of(DECLINED)

    def test_decline_and_no_install(self):
        self.assertEqual(self.summary["declined"], 1)
        self.assertFalse(self.summary["installed"])
        self.assertIsNone(self.summary["installed_id"])
        self.assertIn("declined", self.summary["install_message"])

    def test_stops(self):
        self.assertEqual(self.summary["stop_reasons"], ["failed: The network connection was lost.", "cancelled"])
        self.assertEqual(self.summary["stop_reason"], "cancelled")
        self.assertEqual(self.summary["user_stopped"], 1)
        self.assertEqual(self.summary["failed_responses"], 1)
        self.assertEqual(self.summary["user_messages"], 2)

    def test_cost_is_estimated_without_cost_field(self):
        # 1,000 input and 1,000 output tokens at Sonnet 5.5 prices ($2 and $10 per million).
        self.assertAlmostEqual(self.summary["cost_usd"], 0.012, places=6)
        self.assertEqual(self.summary["model"], "claude-sonnet-5-5")


class OutputTests(unittest.TestCase):
    def test_markdown_table_and_totals(self):
        status, text = run_main([FIXTURES])
        self.assertEqual(status, 0)
        lines = text.splitlines()
        self.assertTrue(lines[0].startswith("| Log | Request | Model |"))
        rows = [line for line in lines if line.startswith("| 2026-")]
        self.assertEqual(len(rows), 2)
        self.assertIn("toggle-dark-mode", rows[0])
        # A pipe in the request is escaped so the table keeps its columns.
        self.assertIn("\\|", rows[1])
        self.assertIn("**Totals:** 2 conversation(s), 1 installed, 1 tested as working", text)
        self.assertIn("1 unreadable line(s) skipped.", text)

    def test_json(self):
        status, text = run_main(["--json", INSTALLED, DECLINED])
        self.assertEqual(status, 0)
        data = json.loads(text)
        self.assertEqual(len(data["conversations"]), 2)
        self.assertEqual(data["totals"]["installed"], 1)
        self.assertEqual(data["totals"]["api_requests"], 10)
        self.assertEqual(data["totals"]["tools"]["request_install"], 2)

    def test_empty_folder(self):
        with tempfile.TemporaryDirectory() as folder:
            status, text = run_main([folder])
        self.assertEqual(status, 0)
        self.assertIn("No conversation logs found.", text)

    def test_cost_estimate_prices(self):
        usage = {"input_tokens": 1_000_000, "output_tokens": 0,
                 "cache_read_input_tokens": 1_000_000, "cache_creation_input_tokens": 1_000_000}
        # Opus 5.5: $4 input + $0.20 cache read + $5 cache write (1.25x input).
        self.assertAlmostEqual(report.estimate_cost("claude-opus-5-5", usage), 9.2)
        # Unknown models are priced as Opus 5.5.
        self.assertAlmostEqual(report.estimate_cost("claude-future", usage), 9.2)


if __name__ == "__main__":
    unittest.main()
