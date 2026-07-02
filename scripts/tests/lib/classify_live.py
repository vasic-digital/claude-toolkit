#!/usr/bin/env python3
"""classify_live.py — classify a Claude Code launch transcript.

Reads a CLI (--output-format json) or TUI (PTY) transcript on stdin and prints
one line: <VERDICT>|<detail>, where VERDICT is PASS / FUNDS / BADKEY / NOKEY /
FAIL. Account problems (funds, bad/empty key) are reported distinctly so they
are never miscounted as toolkit bugs. Argv[1] = "cli" or "tui".
"""
import sys, json, re

mode = sys.argv[1] if len(sys.argv) > 1 else "cli"
raw = sys.stdin.read()
low = raw.lower()

FUNDS = re.compile(r"insufficient|not_enough_balance|balance|credits|quota|payment|suspend|precondition_failed|402|1113|arrears|recharge", re.I)
BADKEY = re.compile(r"invalid api key|incorrect api key|not authorized|unauthorized|\b401\b|paid_model_auth_required|api key not valid", re.I)
NOKEY = re.compile(r"is empty \(set it in|keyvar .* empty", re.I)


def out(v, d=""):
    print("%s|%s" % (v, d[:80].replace("|", " ").replace("\n", " ")))
    sys.exit()


if mode == "cli":
    lines = [l for l in raw.splitlines() if l.strip().startswith("{") and '"type":"result"' in l]
    if lines:
        try:
            d = json.loads(lines[-1])
            res = d.get("result") or ""
            ae = d.get("api_error_status")
            if d.get("subtype") == "success" and not d.get("is_error") and not ae:
                out("PASS", res.strip())
            blob = (str(ae) + " " + res).lower()
            if FUNDS.search(blob): out("FUNDS", res)
            if BADKEY.search(blob): out("BADKEY", res)
            out("FAIL", "api_error=%s %s" % (ae, res))
        except Exception:
            pass

if NOKEY.search(raw): out("NOKEY", "key var empty")
if FUNDS.search(low):
    m = FUNDS.search(low); out("FUNDS", raw[max(0, m.start() - 10):m.start() + 45])
if BADKEY.search(low):
    m = BADKEY.search(low); out("BADKEY", raw[max(0, m.start() - 10):m.start() + 45])

if mode == "tui":
    err = re.search(r"api error|issue with the selected model|error from provider|failed to authenticate", low)
    if err: out("FAIL", raw[err.start():err.start() + 80])
    if re.search(r"claude code v|for shortcuts|esc to interrupt|thought for|\btokens\b", low):
        out("PASS", "tui booted + responded (no error banner)")
    out("FAIL", "tui produced no recognizable response")

m = re.search(r"error[^\n]{0,80}", low)
out("FAIL", m.group(0) if m else "no result")
