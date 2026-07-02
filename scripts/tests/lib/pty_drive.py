#!/usr/bin/env python3
"""pty_drive.py — drive Claude Code's interactive TUI under a pseudo-terminal.

Launches a command (a provider alias wrapper) in a real PTY, waits for the
TUI to boot, types a prompt, lets it run for a fixed window, captures the full
terminal transcript (ANSI-stripped), then quits cleanly. The caller classifies
the transcript (PASS / FUNDS / BADKEY / FAIL) by scanning for signatures.

This is a best-effort SMOKE test of the TUI path — it proves the alias boots a
real Claude Code session and either produces a response or a specific error. It
does NOT assert exact assistant content (TUI redraws make that unreliable); the
authoritative pass/fail is the CLI (-p) path. Its job is to catch the class of
failure the user reported: opening an alias and getting an API error banner.

Usage:
  pty_drive.py --prompt "/using-superpowers" --boot 25 --run 60 -- \
     bash -lc 'source ~/.local/share/.../aliases.sh; cma_run_provider kilo'
Exit code: 0 always (classification is the caller's job); prints transcript.
"""
import argparse
import os
import re
import sys
import time

try:
    import pexpect
except Exception as e:  # pragma: no cover
    sys.stderr.write("pty_drive: pexpect unavailable: %s\n" % e)
    sys.exit(3)

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][AB0]|\x1b[=>]|\r")
# Trust / onboarding prompts a fresh config dir may show.
TRUST = re.compile(r"trust the files|Do you trust|Yes, proceed|press enter to continue", re.I)
# Signs the input box is ready for typing.
READY = re.compile(r"│\s*>|Try \"|shortcuts|/help|esc to|\?\s*for shortcuts", re.I)


def strip(s):
    return ANSI.sub("", s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--boot", type=int, default=25, help="seconds to wait for TUI to become ready")
    ap.add_argument("--run", type=int, default=60, help="seconds to let the prompt run")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    cmd = a.cmd[1:] if a.cmd and a.cmd[0] == "--" else a.cmd
    if not cmd:
        sys.stderr.write("pty_drive: no command\n")
        sys.exit(2)

    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    # Scrub nested-session leakage so the child behaves like a fresh user shell.
    for k in ("CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_ENTRYPOINT",
              "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_EXECPATH", "CLAUDE_EFFORT",
              "CLAUDE_CONFIG_DIR", "ANTHROPIC_MODEL", "ANTHROPIC_BASE_URL",
              "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
        env.pop(k, None)

    buf = []
    child = pexpect.spawn(cmd[0], cmd[1:], env=env, encoding="utf-8",
                          codec_errors="replace", dimensions=(50, 200), timeout=2)

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                data = child.read_nonblocking(size=8192, timeout=1)
                if data:
                    buf.append(data)
            except pexpect.TIMEOUT:
                continue
            except pexpect.EOF:
                break

    # Boot: pump output, accepting any trust prompt, until READY or boot timeout.
    boot_end = time.time() + a.boot
    ready = False
    while time.time() < boot_end:
        try:
            data = child.read_nonblocking(size=8192, timeout=1)
        except pexpect.TIMEOUT:
            data = ""
        except pexpect.EOF:
            break
        if data:
            buf.append(data)
            clean = strip("".join(buf[-40:]))
            if TRUST.search(clean):
                try:
                    child.sendline("")  # accept default (Yes/continue)
                except Exception:
                    pass
                time.sleep(1.0)
            if READY.search(clean):
                ready = True
                break
    # Give it a beat even if READY heuristic missed.
    if not ready:
        time.sleep(2)

    # Type the prompt, then Enter.
    try:
        child.send(a.prompt)
        time.sleep(0.5)
        child.send("\r")
    except Exception as e:
        sys.stderr.write("pty_drive: send failed: %s\n" % e)

    # Let it run, collecting output.
    pump(a.run)

    # Quit cleanly: try /exit, then Ctrl-C twice.
    try:
        child.send("\r")
        child.sendline("/exit")
        time.sleep(1.5)
        child.sendcontrol("c")
        time.sleep(0.3)
        child.sendcontrol("c")
    except Exception:
        pass
    try:
        child.close(force=True)
    except Exception:
        pass

    transcript = strip("".join(buf))
    # Collapse whitespace-heavy TUI redraws for readability.
    transcript = re.sub(r"[ \t]+\n", "\n", transcript)
    transcript = re.sub(r"\n{3,}", "\n\n", transcript)
    sys.stdout.write(transcript)


if __name__ == "__main__":
    main()
