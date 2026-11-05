# Evaluating the agent

How to run the automation backlog (GitHub issues labelled `automation-idea`, #11–#20) through
the chat on a real Mac, measure each attempt, and record the results so runs can be compared
across releases, models and prompt changes.

`Examples/` holds a reference implementation of every backlog idea. Use it to judge the
agent's draft (approach, permissions, edge cases, tests), not to give the agent hints: the
agent sees only the installed automations and its reference library.

## Before a session

- Build and install the app (`make build` or a release DMG), open it once, and finish the
  Setup checklist: API key, runner running, Accessibility and notifications for the runner.
- Remove automations from earlier sessions that use the same hotkeys (Catalog > Remove), so the
  agent is not tempted to reuse them and the hotkeys are free.
- Note the app version (About), macOS version, model and effort (Settings). Keep the spend cap
  at its default ($2.00) unless the session is about cost limits.
- For #17, decide up front whether the "Turn On Do Not Disturb" shortcut exists. The interesting
  case is that it does not: the agent should find that out (`list_shortcuts`) and ask you to
  create it, not invent a Focus API.
- For #16, keep a few old files in `~/Downloads` (or check what is there): the run is real.

## Running one idea

1. **New conversation.** Chat > New Conversation, so each idea gets its own log file.
2. **Paste the request** from the issue's "Request to give the agent" block, verbatim. Do not
   add hints. If the agent asks a question, answer briefly and only what was asked.
3. **Cards.** Read every card before answering:
   - `run_snippet`: approve when the snippet only reads or is clearly harmless; decline (with
     a reason) anything that would change your data during exploration, for example a real
     move in #16 without a dry run. Record each decline.
   - install card: check the trigger, permissions, `destructive` and the validation report.
     Approve if it is what you asked for; otherwise decline with the reason.
   - test card: do exactly what it says, then answer Works or Didn't Work with a short note.
4. **Try it for real** beyond the agent's test: the edge cases listed in the issue ("Things to
   watch for"), for example an empty Finder selection, no Safari window, Cancel in a dialog,
   two displays.
5. **Stop** when it works, when you have declined twice for the same reason, or when the spend
   cap or tool-round cap ends the turn. Do not fix the automation by hand.
6. **Run the report** (below) on that conversation's log and paste the row into the issue.

The log of the current conversation is in
`~/Library/Application Support/AutomationAgent/conversations/`, named
`<start time>-<id prefix>.jsonl`; the newest file is the current one.

## The report

```sh
scripts/conversation-report.py                          # every conversation, markdown
scripts/conversation-report.py ~/Library/Application\ Support/AutomationAgent/conversations/2026-11-05T10-00-00Z-1a2b3c4d.jsonl
scripts/conversation-report.py --json > results.json     # everything, machine-readable
```

It needs only the stock `python3` (3.9 or later, standard library). Arguments are log files
or folders; with none it reads the conversations folder. For each conversation it prints:

| Column | Meaning |
| --- | --- |
| Request | the first message you sent |
| Model | the model in the first request's settings (JSON also lists every model that answered, so fallbacks show) |
| API req. | requests sent to the Messages API (one per tool round, plus the final answer) |
| Tool calls | tool calls, with the number that returned an error |
| Tools | which tools, with counts |
| Approved / declined | answers on snippet, install and status cards |
| Installed | the automation id if `request_install` succeeded, "no" if an install was asked for but did not happen |
| Test | your answer on the test card: works, didn't work |
| Stop | why the agent loop last ended: completed, cancelled, max_tool_rounds_reached, spend_cap_reached, failed: ... |
| Tokens, Cost | all input (uncached, cache reads, cache writes) and output tokens; cost is the app's own estimate per response (Opus 5.5 $4/$20 per million, Sonnet 5.5 $2/$10, cache reads $0.20, cache writes 1.25x input) |
| Duration | from the first to the last line of the log, so it includes the time you took to answer cards |

`--json` adds tool rounds, failed responses, snippet approvals, cancelled cards, every stop
reason, the install message, test notes and unreadable lines.

The report's tests use synthetic logs in `scripts/fixtures/`. CI does not run them; run them
after changing the script or the log format:

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
```

If `ConversationLog.swift` or the card logging in `ChatController.swift` changes, update the
script and the fixtures together.

## What to record per idea

Paste this into the issue as a comment, one per attempt:

```markdown
**Run** 2026-11-05 · app 0.2.0 (12) · macOS 26.1 · claude-opus-5-5, effort high
**Log** `2026-11-05T10-00-00Z-1a2b3c4d.jsonl`

| Installed | First try | Test | API req. | Tool calls | Declines | Cost | Duration |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| toggle-dark-mode | yes | works | 7 | 6 | 0 | $0.24 | 4m 05s |

- Approach: (layer chosen, steps, permissions; compare with Examples/<id>)
- Tests in the draft: (unit / harness / script; meaningful or token)
- Edge cases tried: (what you did, what happened)
- Problems: (wrong API, missing permission, timeouts, focus, card confusion...)
- Follow-up issues: #...
```

"First try" means installed and working with no declines and no "Didn't work" answer.

## Results table

Keep one table per session in the tracking issue or in the release notes:

| Issue | Idea | Installed | First try | Works | API req. | Tool calls | Declines | Cost | Notes |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| #11 | Paste as plain text | | | | | | | | |
| #12 | Safari tab as Markdown link | | | | | | | | |
| #13 | Copy Finder paths | | | | | | | | |
| #14 | Quick reminder | | | | | | | | |
| #15 | Today's events | | | | | | | | |
| #16 | Archive downloads (destructive) | | | | | | | | |
| #17 | Meeting mode (Shortcut) | | | | | | | | |
| #18 | Toggle dark mode | | | | | | | | |
| #19 | Window to left half | | | | | | | | |
| #20 | Title Case selection | | | | | | | | |
| | **Total** | n/10 | n/10 | n/10 | sum | sum | sum | sum | |

Comparing sessions: success rate (Works / 10), first-try rate, median API requests and cost
per idea, and which ideas regressed. A change to the system prompt or the reference library
is an improvement only if it does not make other ideas worse.
