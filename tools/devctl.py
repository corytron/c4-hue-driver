#!/usr/bin/env python3
"""CLI for the dev loop (docs/dev-loop.md). Talks to tools/devserver.py over
its plain-HTTP port; `log` reads build/dev/driver.log directly, so run it on
the VM the server runs on.

  devctl.py status                               versions, last contact, properties
  devctl.py run "Connection Test" Target=Bridge  queue ExecuteCommand(name, params)
  devctl.py set "Stream Timeout (s)" 60          queue a property change
  devctl.py reload                               queue a reload of the current code
  devctl.py wait <id> [--timeout 60]             block until the driver reports the
                                                 command done, then show properties
  devctl.py log [-n 50] [-f]                     show / follow the shipped driver log

`run`, `set` and `reload` print only the queued command's id, so
`devctl.py wait $(devctl.py run "Connection Test")` works.

Exit codes: 0 success, 1 error (server unreachable, bad arguments), 2 timeout.
Standard library only.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

EXIT_OK, EXIT_ERROR, EXIT_TIMEOUT = 0, 1, 2
DEFAULT_SERVER = "http://127.0.0.1:8080"
DEFAULT_LOG = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build", "dev", "driver.log")


class DevctlError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


# ---------------------------------------------------------------------------
# Talking to the server
# ---------------------------------------------------------------------------

def api(server, method, path, body=None):
    """One request to the server. Returns the decoded JSON reply (None for 204)."""
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(server + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace").strip()
        raise DevctlError("%s %s -> HTTP %d %s" % (method, path, exc.code, detail))
    except (urllib.error.URLError, OSError) as exc:
        raise DevctlError("devserver not reachable at %s (%s)" % (server, exc.reason if hasattr(exc, "reason") else exc))
    if not raw:
        return None
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError as exc:
        raise DevctlError("%s %s returned something that is not JSON (%s)" % (method, path, exc))


def enqueue(args, command):
    reply = api(args.server, "POST", "/admin/enqueue", command)
    if not isinstance(reply, dict) or not isinstance(reply.get("id"), int):
        raise DevctlError("unexpected reply from /admin/enqueue: %r" % (reply,))
    return reply["id"]


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def short(version):
    return version[:12] if isinstance(version, str) and version else "-"


def ago(unix_time, server_time=None):
    if not isinstance(unix_time, (int, float)):
        return "never"
    reference = server_time if isinstance(server_time, (int, float)) else time.time()
    return "%ds ago" % max(0, int(round(reference - unix_time)))


def describe(command):
    kind = command.get("type")
    if kind == "execute":
        params = command.get("params") or {}
        extra = " " + " ".join("%s=%s" % kv for kv in sorted(params.items())) if params else ""
        return "#%s execute %r%s" % (command.get("id"), command.get("command"), extra)
    if kind == "set_property":
        return "#%s set %r = %r" % (command.get("id"), command.get("name"), command.get("value"))
    return "#%s %s" % (command.get("id"), kind)


def print_properties(properties):
    if not properties:
        print("properties       (none reported)")
        return
    print("properties:")
    width = max(len(str(name)) for name in properties)
    for name in sorted(properties, key=str):
        print("  %-*s = %s" % (width, name, properties[name]))


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

def cmd_status(args):
    st = api(args.server, "GET", "/status")
    running, local = st.get("running_version"), st.get("local_version")
    if not running:
        note = "driver has not reported yet"
    elif running == local:
        note = "matches local"
    else:
        note = "DIFFERS from local; a reload is due"
    print("running_version  %s  (%s)" % (short(running), note))
    print("local_version    %s" % short(local))
    print("last_seen        %s" % ago(st.get("last_seen"), st.get("server_time")))
    print("last_event       %s" % (st.get("last_event") or "-"))
    if st.get("last_error"):
        print("last_error       %s" % st["last_error"])
    pending = st.get("pending_commands") or []
    print("pending          %d command(s)" % len(pending))
    for command in pending:
        print("  %s" % describe(command))
    print_properties(st.get("properties") or {})
    return EXIT_OK


def parse_params(pairs):
    params = {}
    for pair in pairs:
        key, sep, value = pair.partition("=")
        if not sep or not key:
            raise DevctlError("parameter %r is not Key=Value" % pair)
        params[key] = value
    return params


def cmd_run(args):
    command = {"type": "execute", "command": args.command, "params": parse_params(args.params)}
    print(enqueue(args, command))
    return EXIT_OK


def cmd_set(args):
    print(enqueue(args, {"type": "set_property", "name": args.name, "value": args.value}))
    return EXIT_OK


def cmd_reload(args):
    print(enqueue(args, {"type": "reload"}))
    return EXIT_OK


def cmd_wait(args):
    deadline = time.monotonic() + args.timeout
    while True:
        st = api(args.server, "GET", "/status")
        done = st.get("done_commands")
        if isinstance(done, list):
            finished = args.id in done
        else:  # older server without the list: fall back to the high-water mark
            finished = isinstance(st.get("last_done_id"), int) and st["last_done_id"] >= args.id
        if finished:
            print_properties(st.get("properties") or {})
            return EXIT_OK
        if time.monotonic() >= deadline:
            pending = [c.get("id") for c in st.get("pending_commands") or []]
            state = "still pending" if args.id in pending else "not pending and not done; was it ever queued?"
            sys.stderr.write("timed out after %gs waiting for command %d (%s)\n" % (args.timeout, args.id, state))
            return EXIT_TIMEOUT
        time.sleep(1)


def tail_lines(path, count):
    """Return the last `count` lines of the file and the offset of its end."""
    with open(path, "rb") as f:
        data = f.read()
    lines = data.splitlines(keepends=True)
    return lines[-count:] if count > 0 else [], len(data)


def cmd_log(args):
    path = args.file
    if not os.path.exists(path):
        if not args.follow:
            raise DevctlError("no log yet at %s" % path)
        sys.stderr.write("waiting for %s to appear...\n" % path)
        while not os.path.exists(path):
            time.sleep(0.5)
    lines, offset = tail_lines(path, args.lines)
    sys.stdout.buffer.write(b"".join(lines))
    sys.stdout.flush()
    if not args.follow:
        return EXIT_OK
    # Follow by polling the file size; a shrink means it was truncated or
    # replaced, so start again from the top.
    try:
        while True:
            time.sleep(0.5)
            try:
                size = os.path.getsize(path)
            except OSError:
                continue
            if size < offset:
                offset = 0
            if size == offset:
                continue
            with open(path, "rb") as f:
                f.seek(offset)
                chunk = f.read()
            offset += len(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.flush()
    except KeyboardInterrupt:
        return EXIT_OK


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Control the hue_bridge dev loop (docs/dev-loop.md).")
    parser.add_argument("--server", default=DEFAULT_SERVER, help="devserver plain-HTTP base URL (default %s)" % DEFAULT_SERVER)
    sub = parser.add_subparsers(dest="cmd", metavar="command")
    sub.required = True

    sub.add_parser("status", help="show versions, last contact and properties").set_defaults(func=cmd_status)

    p = sub.add_parser("run", help="queue an ExecuteCommand action")
    p.add_argument("command", help="action name, e.g. \"Connection Test\"")
    p.add_argument("params", nargs="*", help="parameters as Key=Value")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("set", help="queue a property change")
    p.add_argument("name", help="property name")
    p.add_argument("value", help="new value (sent as a string)")
    p.set_defaults(func=cmd_set)

    sub.add_parser("reload", help="queue a reload of the running code").set_defaults(func=cmd_reload)

    p = sub.add_parser("wait", help="wait for a queued command to finish")
    p.add_argument("id", type=int, help="command id as printed by run/set/reload")
    p.add_argument("--timeout", type=float, default=60, help="seconds to wait (default 60)")
    p.set_defaults(func=cmd_wait)

    p = sub.add_parser("log", help="show the shipped driver log")
    p.add_argument("-n", "--lines", type=int, default=50, help="how many trailing lines (default 50)")
    p.add_argument("-f", "--follow", action="store_true", help="keep printing as lines arrive")
    p.add_argument("--file", default=DEFAULT_LOG, help="log file (default %s)" % DEFAULT_LOG)
    p.set_defaults(func=cmd_log)

    args = parser.parse_args()
    args.server = args.server.rstrip("/")
    try:
        return args.func(args)
    except DevctlError as exc:
        sys.stderr.write("devctl: %s\n" % exc)
        return EXIT_ERROR
    except KeyboardInterrupt:
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
