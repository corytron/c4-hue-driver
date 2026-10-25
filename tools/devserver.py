#!/usr/bin/env python3
"""Dev-loop server for the hue_bridge dev build. The contract is docs/dev-loop.md.

Two listeners share one handler, both on one address (--bind; by default this
VM's LAN address, never every address unless --bind 0.0.0.0 says so):
  plain HTTP (--port, default 8080)     the dev loop: /manifest /bundle /file
                                        /commands /log /report /status /admin/*
  TLS        (--tls-port, default 8443) the same endpoints, plus the C4:url
                                        connection experiment points here:
                                        /stream (endless text/event-stream) and /ping
The TLS certificate is self-signed, generated with openssl into --cert-dir on
first run; the driver talks to it in "insecure" mode, so its contents don't matter.

Three served trees (published path -> file), each exactly the layout
tools/build.sh stages for that driver; /manifest, /bundle and /file take
?tree=bridge (the default), ?tree=light or ?tree=scene:
  bridge: src/hue_bridge/**/*.lua, **/*.xml, certs/*  ->  driver.lua, bridge/http.lua, certs/x.pem
  light:  src/hue_light/**/*.lua, **/*.xml, certs/*   ->  driver.lua, light/state.lua
  scene:  src/hue_scene/**/*.lua, **/*.xml, certs/*   ->  driver.lua, scene/...
  all:    src/common/*.lua                            ->  common/log.lua
A file named devkey.lua is never served. A tree's version is sha1 over, in
sorted published-path order, path + "\\0" + contents. It is recomputed on every
/manifest and /bundle. Only the bridge driver talks to this server; it forwards
the light and scene trees to its bound devices itself (docs/dev-loop.md).

Security (docs/dev-loop.md, "Security"): the dev key, 64 lowercase hex
characters in ~/.config/c4-hue-driver/devkey (0600; C4_HUE_DEVKEY_FILE or
--key-file name another file; created on first run, never printed), keys
HMAC-SHA256 over "c4-hue-devloop/1\\n<label>\\n<data>". /bundle and /commands
answer "<mac>\\n<payload>", signed under "bundle" and "commands" (the latter over
the driver's nonce too); tools/build.sh --dev bakes the same key into the dev
packages, which check every bundle and command list before using it. /status
and /admin/* want the header X-Devloop-Token, the "admin-token" MAC of
nothing, which tools/devctl.py derives from the key file.

State lives under --state-dir (default build/dev, gitignored):
  driver.log     one "HH:MM:SS.mmm <line>" per shipped log line (echoed to
                 stdout as "LOG HH:MM:SS.mmm <line>")
  reports.jsonl  one JSON object per /report, with "received" (unix time) added
  commands.json  {"next_id": N, "commands": [pending...], "done": [ids]}; loaded
                 at startup so ids keep increasing across restarts
  server.json    {"url": ..., "tls_url": ..., "pid": ...} while the server runs;
                 tools/devctl.py finds the server through it

Console output: every connection open is logged with client address and, on
TLS, protocol/cipher/ALPN; that is what the connection experiment reads off the
console. Each request line is logged too. --quiet drops the connection and
request lines on the plain listener (the dev loop polls every 3 s) and the
heartbeat report summaries; LOG lines, other reports, refusals and errors stay.

Usage: tools/devserver.py [--port 8080] [--tls-port 8443] [--bind ADDRESS]
                          [--key-file FILE] [--root DIR] [--cert-dir DIR]
                          [--state-dir DIR] [--quiet]
       tools/devserver.py --ensure-key [--key-file FILE]
                          create the key if missing, check it, print its path
Standard library only.
"""

import argparse
import datetime
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import socket
import ssl
import stat
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PRINT_LOCK = threading.Lock()


def emit(text):
    """Write one line to stdout from any thread without interleaving."""
    with PRINT_LOCK:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()


def log(msg):
    emit(time.strftime("%H:%M:%S") + " " + msg)


def fmt_ms(ms):
    """Milliseconds since the epoch -> local HH:MM:SS.mmm."""
    dt = datetime.datetime.fromtimestamp(ms / 1000.0)
    return dt.strftime("%H:%M:%S") + ".%03d" % (dt.microsecond // 1000)


def now():
    return round(time.time(), 3)


# ---------------------------------------------------------------------------
# The dev key and what it signs (docs/dev-loop.md, "Security")
# ---------------------------------------------------------------------------

KEY_FILE_ENV = "C4_HUE_DEVKEY_FILE"
KEY_RE = re.compile(r"[0-9a-f]{64}")
KEY_MODULE = "devkey.lua"  # what tools/build.sh --dev bakes into a package; never served
DOMAIN = b"c4-hue-devloop/1\n"
TOKEN_HEADER = "X-Devloop-Token"
NONCE_RE = re.compile(r"[0-9a-f]{16,64}")
SIGNED_TYPE = "application/x-c4hue-signed"  # "<mac>\n<JSON payload>"


class DevKeyError(Exception):
    """The dev key file is missing, too open or malformed. The message never holds the key."""


def default_key_file(environ=None):
    """$C4_HUE_DEVKEY_FILE, else $XDG_CONFIG_HOME/c4-hue-driver/devkey, else
    ~/.config/c4-hue-driver/devkey: outside the repository."""
    environ = os.environ if environ is None else environ
    explicit = environ.get(KEY_FILE_ENV)
    if explicit:
        return os.path.abspath(os.path.expanduser(explicit))
    config = environ.get("XDG_CONFIG_HOME")
    if not config or not os.path.isabs(config):
        config = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(config, "c4-hue-driver", "devkey")


def load_key(path):
    """The key as bytes: its 64 hex characters, which are what keys the HMAC
    (on the controller too, as ASCII). Refuses a file group or others can
    read, and anything but 64 lowercase hex characters."""
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except FileNotFoundError:
        raise DevKeyError(
            "no dev key at %s: start tools/devserver.py once, or run tools/devserver.py --ensure-key" % path
        ) from None
    if mode & 0o077:
        raise DevKeyError(
            "%s can be read by others (mode %03o): chmod 600 it, or delete it for a new key" % (path, mode)
        )
    with open(path, "r", encoding="ascii", errors="replace") as f:
        text = f.read().strip()
    if not KEY_RE.fullmatch(text):
        raise DevKeyError("%s does not hold 64 lowercase hex characters: delete it for a new key" % path)
    return text.encode("ascii")


def ensure_key(path):
    """Create the key file if it is missing: 32 random bytes as hex, 0600, in
    a 0700 directory. Returns (key, created)."""
    created = False
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass  # created by another process meanwhile
        else:
            with os.fdopen(fd, "w", encoding="ascii") as f:
                f.write(secrets.token_hex(32) + "\n")
            created = True
    return load_key(path), created


def mac(key, label, data):
    """HMAC-SHA256 with the key over DOMAIN + label + "\\n" + data, lowercase hex."""
    return hmac.new(key, DOMAIN + label.encode("ascii") + b"\n" + data, hashlib.sha256).hexdigest()


def fingerprint(key):
    """16 hex characters that name a key without revealing it."""
    return mac(key, "fingerprint", b"")[:16]


def admin_token(key):
    """What /status and /admin/* want in X-Devloop-Token."""
    return mac(key, "admin-token", b"")


def envelope(key, label, payload_obj):
    """A signed answer: "<mac>\\n<payload>", the MAC over the payload's exact
    bytes (compact JSON, ASCII only)."""
    payload = json.dumps(payload_obj, separators=(",", ":")).encode("ascii")
    return mac(key, label, payload).encode("ascii") + b"\n" + payload


# ---------------------------------------------------------------------------
# The address to listen on
# ---------------------------------------------------------------------------

# TEST-NET-2 (RFC 5737). Connecting a UDP socket sends nothing: the kernel
# only picks the route, and so the source address, it would use.
ROUTE_PROBE = ("198.51.100.1", 9)


def lan_address(probe=ROUTE_PROBE):
    """This VM's LAN address: the source address of its default route. None
    when there is none (no route, or only loopback)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(probe)
            address = s.getsockname()[0]
    except OSError:
        return None
    if not address or address == "0.0.0.0" or address.startswith("127."):
        return None
    return address


def choose_bind(requested, detect=None):
    """The address both listeners bind: --bind when given (0.0.0.0 only then),
    else the LAN address (`detect`, default lan_address, looked up when
    called); None when that cannot be found."""
    if requested:
        return requested
    return (detect or lan_address)()


def url_host(bind):
    """Where a client on this VM reaches a listener bound to `bind`."""
    return "127.0.0.1" if bind in ("0.0.0.0", "") else bind


# ---------------------------------------------------------------------------
# The served tree
# ---------------------------------------------------------------------------

TREES = ("bridge", "light", "scene")


class Tree:
    """The source files of one driver, src/hue_<name> with src/common mounted
    as common/. Listed afresh on every call: a few dozen small files, so there
    is nothing worth caching (and nothing to go stale)."""

    def __init__(self, root, name):
        self.name = name
        self.driver = os.path.join(root, "src", "hue_" + name)
        self.common = os.path.join(root, "src", "common")
        self.pinned = None  # (version, contents) served instead of the live tree while pinned

    def files(self):
        """Return {published_path: absolute_path}. Published paths are relative
        with forward slashes, e.g. "driver.lua", "bridge/http.lua", "common/log.lua".
        A devkey.lua is never among them."""
        out = {}
        for dirpath, dirnames, filenames in os.walk(self.driver):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
            rel_dir = os.path.relpath(dirpath, self.driver)
            in_certs = rel_dir.split(os.sep)[0] == "certs"
            for name in filenames:
                if name.startswith(".") or name == KEY_MODULE:
                    continue
                if not (in_certs or name.endswith(".lua") or name.endswith(".xml")):
                    continue
                rel = name if rel_dir == "." else os.path.join(rel_dir, name)
                out[rel.replace(os.sep, "/")] = os.path.join(dirpath, name)
        if os.path.isdir(self.common):
            for name in os.listdir(self.common):
                full = os.path.join(self.common, name)
                if name.endswith(".lua") and name != KEY_MODULE and os.path.isfile(full):
                    out["common/" + name] = full
        return out

    def snapshot(self):
        """What is served right now: the pinned snapshot while pinned, else
        the live tree. Returns (version, {published_path: bytes})."""
        if self.pinned is not None:
            return self.pinned
        return self.read()

    def pin(self):
        """Serve the tree as it is at this moment until unpin(); pinning again
        re-reads it. For stretches when several agents edit src/ at once and
        the controller must only see states the coordinator has checked."""
        self.pinned = self.read()
        return self.pinned[0]

    def unpin(self):
        self.pinned = None

    def read(self):
        """Read every served file from disk. Returns (version, {published_path: bytes})."""
        files = self.files()
        contents = {}
        digest = hashlib.sha1()
        for path in sorted(files):
            with open(files[path], "rb") as f:
                data = f.read()
            contents[path] = data
            digest.update(path.encode("utf-8"))
            digest.update(b"\0")
            digest.update(data)
        return digest.hexdigest(), contents


# ---------------------------------------------------------------------------
# Server state: the command queue and what the driver last told us
# ---------------------------------------------------------------------------


class State:
    """Everything remembered between requests, guarded by one lock.

    A command sits in the pending queue until the driver reports command_done
    for it, then moves to the done list. A driver that comes up fresh (asking
    after=0) therefore re-receives only commands nobody has acknowledged, not
    the whole history."""

    DONE_KEEP = 200  # finished ids kept for /status and `devctl wait`

    def __init__(self, state_dir):
        self.lock = threading.Lock()
        os.makedirs(state_dir, exist_ok=True)
        self.log_path = os.path.join(state_dir, "driver.log")
        self.reports_path = os.path.join(state_dir, "reports.jsonl")
        self.commands_path = os.path.join(state_dir, "commands.json")
        self.next_id = 1
        self.commands = []  # pending commands, in id order
        self.done = []  # ids the driver reported command_done for, oldest first
        self.running_version = None
        self.running_light_version = None  # what the bridge last forwarded to its lights
        self.running_scene_version = None  # ... and to its scene devices
        self.last_seen = None
        self.last_event = None
        self.last_error = None  # text of the most recent report that carried "error"
        self.properties = {}
        self.driver_key_fingerprint = None  # what the bridge's last report named
        self.reported_key = False  # whether any report has said which key the driver has
        self.warned_fingerprint = None  # the driver fingerprint last warned about
        self._load_commands()

    def _load_commands(self):
        if not os.path.exists(self.commands_path):
            return
        try:
            with open(self.commands_path, "r", encoding="utf-8") as f:
                saved = json.load(f)
            commands = [c for c in saved.get("commands", []) if isinstance(c.get("id"), int)]
            done = [i for i in saved.get("done", []) if isinstance(i, int)]
            next_id = int(saved.get("next_id", 1))
        except (OSError, ValueError, AttributeError, TypeError) as exc:
            log("warning: ignoring unreadable %s (%s)" % (self.commands_path, exc))
            return
        self.commands = sorted(commands, key=lambda c: c["id"])
        self.done = done[-self.DONE_KEEP :]
        highest = max([c["id"] for c in self.commands] + self.done + [0])
        self.next_id = max(next_id, highest + 1)

    def _save_commands(self):
        """Caller holds the lock. Written atomically so a crash mid-write cannot
        leave a truncated file that would reset the ids."""
        tmp = self.commands_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"next_id": self.next_id, "commands": self.commands, "done": self.done}, f, indent=1)
        os.replace(tmp, self.commands_path)

    def touch(self, version=None, light_version=None, scene_version=None):
        """The driver talked to us."""
        with self.lock:
            self.last_seen = now()
            if isinstance(version, str) and version:
                self.running_version = version
            if isinstance(light_version, str) and light_version:
                self.running_light_version = light_version
            if isinstance(scene_version, str) and scene_version:
                self.running_scene_version = scene_version

    def note_fingerprint(self, reported, ours):
        """Record the key fingerprint a report carried (None: the driver has no
        key). Returns a warning line the first time it differs from ours."""
        with self.lock:
            self.reported_key = True
            self.driver_key_fingerprint = reported if isinstance(reported, str) else None
            if self.driver_key_fingerprint == ours or self.driver_key_fingerprint == self.warned_fingerprint:
                return None
            self.warned_fingerprint = self.driver_key_fingerprint
        if self.driver_key_fingerprint is None:
            return (
                "WARNING the driver reports no dev key (a build without one, or from before signing): it can use "
                "no bundle or command from this server; install a dev build made from this commit"
            )
        return (
            "WARNING the driver's dev key (fingerprint %s) is not this server's (%s): it refuses every bundle "
            "and command; install a dev build made with this key, or start the server with that build's key"
            % (self.driver_key_fingerprint, ours)
        )

    def enqueue(self, command):
        with self.lock:
            command["id"] = self.next_id
            self.next_id += 1
            self.commands.append(command)
            self._save_commands()
            return command["id"]

    def commands_after(self, after):
        with self.lock:
            return [c for c in self.commands if c["id"] > after]

    def add_log(self, lines):
        """Append shipped log lines to driver.log and echo them to stdout."""
        out = []
        for item in lines:
            if isinstance(item, dict):
                text = str(item.get("line", ""))
                try:
                    stamp = fmt_ms(float(item["t"]))
                except (KeyError, TypeError, ValueError, OverflowError, OSError):
                    stamp = fmt_ms(time.time() * 1000)
            else:
                text, stamp = str(item), fmt_ms(time.time() * 1000)
            out.append("%s %s" % (stamp, text))
        with self.lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                for line in out:
                    f.write(line + "\n")
        for line in out:
            emit("LOG " + line)

    def add_report(self, report):
        """Record a /report: persist it, update the status fields, return a
        one-line summary for the console."""
        report["received"] = now()
        event = report.get("event")
        command_id = report.get("command_id")
        with self.lock:
            with open(self.reports_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(report) + "\n")
            if isinstance(event, str):
                self.last_event = event
            if isinstance(report.get("properties"), dict):
                self.properties = report["properties"]
            if isinstance(report.get("error"), str):
                self.last_error = report["error"]
            if event == "command_done" and isinstance(command_id, int):
                self.commands = [c for c in self.commands if c["id"] != command_id]
                if command_id not in self.done:
                    self.done.append(command_id)
                    self.done = self.done[-self.DONE_KEEP :]
                self._save_commands()
        summary = "REPORT %s" % event
        if isinstance(command_id, int):
            summary += " cmd=%d" % command_id
        if isinstance(report.get("version"), str):
            summary += " v=%s" % report["version"][:12]
        if isinstance(report.get("light_version"), str):
            summary += " lv=%s" % report["light_version"][:12]
        if isinstance(report.get("scene_version"), str):
            summary += " sv=%s" % report["scene_version"][:12]
        if isinstance(report.get("tree"), str):
            summary += " tree=%s" % report["tree"]
        if isinstance(report.get("refused_version"), str):
            summary += " refused=%s" % report["refused_version"][:12]
        if isinstance(report.get("elapsed_ms"), (int, float)):
            summary += " %dms" % report["elapsed_ms"]
        if isinstance(report.get("properties"), dict):
            summary += " props=%d" % len(report["properties"])
        if report.get("sandbox") is not None:
            summary += " sandbox=%s" % json.dumps(report["sandbox"], separators=(",", ":"))
        if isinstance(report.get("error"), str):
            summary += " error=%s" % report["error"].replace("\n", " ")[:300]
        return summary

    def status(self, local_version, local_light_version, local_scene_version=None):
        """/status. Beyond the fields in docs/dev-loop.md this adds:
        done_commands  ids the driver has reported command_done for (last
                       DONE_KEEP, oldest first); `devctl wait` polls this
        last_done_id   the most recent of those, or null
        last_error     the "error" text of the most recent report that had one
        server_time    unix seconds, so a client can judge last_seen"""
        with self.lock:
            return {
                "running_version": self.running_version,
                "local_version": local_version,
                "running_light_version": self.running_light_version,
                "local_light_version": local_light_version,
                "running_scene_version": self.running_scene_version,
                "local_scene_version": local_scene_version,
                "last_seen": self.last_seen,
                "last_event": self.last_event,
                "last_error": self.last_error,
                "properties": dict(self.properties),
                "pending_commands": list(self.commands),
                "done_commands": list(self.done),
                "last_done_id": self.done[-1] if self.done else None,
                "driver_key_fingerprint": self.driver_key_fingerprint,
                "driver_reported_key": self.reported_key,
                "server_time": now(),
            }


# ---------------------------------------------------------------------------
# HTTP handling
# ---------------------------------------------------------------------------


def as_list(value):
    """Accept a JSON list, or the object Director's C4:JsonEncode produces for
    a Lua array ({"1": ..., "2": ...}, string keys, unordered): return a list
    in key order. Anything else is returned unchanged for the caller to reject."""
    if isinstance(value, list):
        return value
    if isinstance(value, dict) and value and all(k.isdigit() for k in value):
        return [value[k] for k in sorted(value, key=int)]
    return value


def validate_command(body):
    """Check a /admin/enqueue body; return (command, None) or (None, error)."""
    if not isinstance(body, dict):
        return None, "body must be a JSON object"
    kind = body.get("type")
    if kind == "execute":
        if not isinstance(body.get("command"), str) or not body["command"]:
            return None, 'execute needs a non-empty "command" string'
        params = body.get("params", {})
        if not isinstance(params, dict):
            return None, '"params" must be an object'
        return {
            "type": "execute",
            "command": body["command"],
            "params": {str(k): str(v) for k, v in params.items()},
        }, None
    if kind == "set_property":
        if not isinstance(body.get("name"), str) or not body["name"]:
            return None, 'set_property needs a non-empty "name" string'
        if "value" not in body or body["value"] is None:
            return None, 'set_property needs a "value"'
        return {"type": "set_property", "name": body["name"], "value": str(body["value"])}, None
    if kind == "reload":
        return {"type": "reload"}, None
    return None, "unknown type %r (execute, set_property or reload)" % (kind,)


def developer_path(path):
    """The endpoints only the developer calls: they want the admin token."""
    return path == "/status" or path.startswith("/admin/")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep-alive; every reply carries Content-Length or is chunked
    timeout = 120  # idle keep-alive connections are dropped after this
    server_version = "c4-hue-devserver/1"
    sys_version = ""

    GET_ROUTES = {
        "/manifest": "get_manifest",
        "/bundle": "get_bundle",
        "/file": "get_file",
        "/commands": "get_commands",
        "/status": "get_status",
        "/ping": "get_ping",
        "/stream": "get_stream",
    }
    POST_ROUTES = {
        "/log": "post_log",
        "/report": "post_report",
        "/admin/enqueue": "post_enqueue",
        "/admin/pin": "post_pin",
        "/admin/unpin": "post_unpin",
    }

    # -- connection logging ------------------------------------------------

    @property
    def is_tls(self):
        return isinstance(self.connection, ssl.SSLSocket)

    @property
    def chatty(self):
        """Whether connection and request lines go to the console."""
        return self.is_tls or not self.server.quiet

    def log_conn(self, msg):
        log("%s %s:%d  %s" % ("TLS  " if self.is_tls else "HTTP ", self.client_address[0], self.client_address[1], msg))

    def setup(self):
        super().setup()
        if not self.chatty:
            return
        if self.is_tls:
            sock = self.connection
            try:
                detail = "%s %s alpn=%s" % (sock.version(), sock.cipher()[0], sock.selected_alpn_protocol())
            except Exception as exc:  # noqa: BLE001 - only used for the log line
                detail = "tls? %s" % exc
        else:
            detail = "plain"
        self.log_conn("OPEN  " + detail)

    def finish(self):
        super().finish()
        if self.chatty:
            self.log_conn("CLOSE")

    def log_message(self, fmt, *args):
        """Quiet the default access log; requests are logged in dispatch()."""

    # -- dispatch -----------------------------------------------------------

    def do_GET(self):
        self.dispatch("GET", self.GET_ROUTES, self.POST_ROUTES)

    def do_POST(self):
        self.dispatch("POST", self.POST_ROUTES, self.GET_ROUTES)

    def dispatch(self, method, routes, other_routes):
        url = urlsplit(self.path)
        if self.chatty:
            self.log_conn("%-4s  %s" % (method, self.path))
        name = routes.get(url.path)
        if name is None:
            if url.path in other_routes:
                self.send_text(405, "method not allowed\n", allow="POST" if method == "GET" else "GET")
            else:
                self.send_text(404, "not found\n")
            return
        if developer_path(url.path) and not self.authorised(method, url.path):
            return
        getattr(self, name)(parse_qs(url.query))

    def authorised(self, method, path):
        """Whether the request carries the admin token; if not, a 401 has been
        sent and one DENY line logged (without the value presented)."""
        given = self.headers.get(TOKEN_HEADER)
        if given is not None and hmac.compare_digest(
            given.encode("utf-8", "replace"), self.server.admin_token.encode("ascii")
        ):
            return True
        self.close_connection = True  # the body was not read
        log(
            "DENY  %s:%d  %s %s: %s"
            % (
                self.client_address[0],
                self.client_address[1],
                method,
                path,
                "no admin token" if given is None else "wrong admin token",
            )
        )
        self.send_json(
            {"error": "admin token missing or wrong; tools/devctl.py sends it (docs/dev-loop.md, Security)"}, 401
        )
        return False

    # -- replies ------------------------------------------------------------

    def send_body(self, status, body, ctype, allow=None):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if allow:
            self.send_header("Allow", allow)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_body(status, json.dumps(obj).encode("utf-8"), "application/json")

    def send_text(self, status, text, allow=None):
        self.send_body(status, text.encode("utf-8"), "text/plain; charset=utf-8", allow)

    def send_signed(self, label, payload_obj):
        self.send_body(200, envelope(self.server.key, label, payload_obj), SIGNED_TYPE)

    def send_no_content(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_bad_request(self, message):
        self.close_connection = True  # the body may not have been consumed
        raw = getattr(self, "_raw_body", b"")
        snippet = raw[:300].decode("utf-8", "replace")
        log(
            "BAD   %s:%d  %s %s: %s body=%r"
            % (self.client_address[0], self.client_address[1], self.command, self.path, message, snippet)
        )
        self.send_json({"error": message}, 400)

    def read_json_body(self):
        """Parse the JSON request body. Returns (obj, None) or (None, error_text)."""
        length = self.headers.get("Content-Length")
        if length is None:
            return None, "Content-Length required"
        try:
            n = int(length)
        except ValueError:
            return None, "bad Content-Length"
        raw = self.rfile.read(n) if n > 0 else b""
        self._raw_body = raw  # kept so a rejection can be logged with context
        if not raw:
            return None, "empty body"
        try:
            return json.loads(raw.decode("utf-8")), None
        except (UnicodeDecodeError, ValueError) as exc:
            return None, "invalid JSON: %s" % exc

    # -- dev-loop endpoints -------------------------------------------------

    def tree_from(self, query):
        """The tree a request names (?tree=bridge|light|scene, default bridge),
        or None after a 400 has been sent."""
        name = query.get("tree", ["bridge"])[0]
        tree = self.server.trees.get(name)
        if tree is None:
            self.send_bad_request("unknown tree %r (%s)" % (name, " or ".join(TREES)))
        return tree

    def get_manifest(self, query):
        tree = self.tree_from(query)
        if tree is None:
            return
        version, contents = tree.snapshot()
        self.server.state.touch()
        self.send_json({"version": version, "tree": tree.name, "files": sorted(contents), "server_time": now()})

    def get_bundle(self, query):
        """The tree's files, signed (label "bundle"): the driver checks the MAC
        before it decodes anything."""
        tree = self.tree_from(query)
        if tree is None:
            return
        version, contents = tree.snapshot()
        self.server.state.touch()
        files = {path: data.decode("utf-8", "replace") for path, data in contents.items()}
        self.send_signed("bundle", {"version": version, "tree": tree.name, "files": files})

    def get_file(self, query):
        tree = self.tree_from(query)
        if tree is None:
            return
        path = query.get("path", [""])[0]
        files = tree.files()
        # Only published paths are served, so "../x", "/etc/passwd" and the
        # like simply are not in the table and get a 404.
        if not path or path.startswith("/") or ".." in path.split("/") or path not in files:
            self.send_text(404, "no such file\n")
            return
        self.server.state.touch()
        with open(files[path], "rb") as f:
            data = f.read()
        self.send_body(200, data, "text/plain; charset=utf-8")

    def get_commands(self, query):
        """The pending commands after `after`, signed (label "commands")
        together with the nonce the driver sent, so an answer recorded once
        cannot be replayed to it."""
        raw = query.get("after", ["0"])[0]
        try:
            after = int(raw)
        except ValueError:
            self.send_bad_request("after must be an integer")
            return
        nonce = query.get("nonce", [""])[0]
        if not NONCE_RE.fullmatch(nonce):
            self.send_bad_request(
                "nonce must be 16 to 64 lowercase hex characters "
                "(a dev build from before signing? install one made from this commit)"
            )
            return
        self.server.state.touch()
        self.send_signed("commands", {"nonce": nonce, "commands": self.server.state.commands_after(after)})

    def get_status(self, query):
        trees = self.server.trees
        status = self.server.state.status(
            trees["bridge"].snapshot()[0], trees["light"].snapshot()[0], trees["scene"].snapshot()[0]
        )
        # While pinned, local_* are the served (pinned) versions; live_* say
        # what the working tree has become in the meantime.
        status["pinned"] = self.pinned_versions()
        status["live_version"] = trees["bridge"].read()[0]
        status["live_light_version"] = trees["light"].read()[0]
        status["live_scene_version"] = trees["scene"].read()[0]
        status["key_fingerprint"] = self.server.key_fingerprint
        self.send_json(status)

    def post_log(self, query):
        body, err = self.read_json_body()
        if err is None and isinstance(body, dict):
            body["lines"] = as_list(body.get("lines"))
        if err is None and not (isinstance(body, dict) and isinstance(body.get("lines"), list)):
            err = 'expected {"version": ..., "lines": [...]}'
        if err:
            self.send_bad_request(err)
            return
        self.server.state.touch(body.get("version"))
        self.server.state.add_log(body["lines"])
        self.send_no_content()

    def post_report(self, query):
        body, err = self.read_json_body()
        if err is None and not (isinstance(body, dict) and isinstance(body.get("event"), str)):
            err = 'expected {"version": ..., "event": ..., ...}'
        if err:
            self.send_bad_request(err)
            return
        self.server.state.touch(body.get("version"), body.get("light_version"), body.get("scene_version"))
        warning = self.server.state.note_fingerprint(body.get("key_fingerprint"), self.server.key_fingerprint)
        if warning:
            log(warning)
        summary = self.server.state.add_report(body)
        if body["event"] != "heartbeat" or not self.server.quiet:
            log(summary)
        self.send_no_content()

    def post_enqueue(self, query):
        body, err = self.read_json_body()
        if err is None:
            command, err = validate_command(body)
        if err:
            self.send_bad_request(err)
            return
        command_id = self.server.state.enqueue(command)
        log("QUEUE #%d %s" % (command_id, json.dumps(command, separators=(",", ":"))))
        self.send_json({"id": command_id})

    def pinned_versions(self):
        return {name: (tree.pinned[0] if tree.pinned else None) for name, tree in self.server.trees.items()}

    def post_pin(self, query):
        """Pin every tree (or ?tree=bridge|light|scene) to its content right
        now; the controller keeps that version until unpin or the next pin."""
        names = query.get("tree") or list(self.server.trees)
        for name in names:
            tree = self.server.trees.get(name)
            if tree is None:
                self.send_bad_request("unknown tree %r" % name)
                return
            log("PIN %s tree at %s" % (name, tree.pin()[:12]))
        self.send_json({"pinned": self.pinned_versions()})

    def post_unpin(self, query):
        names = query.get("tree") or list(self.server.trees)
        for name in names:
            tree = self.server.trees.get(name)
            if tree is None:
                self.send_bad_request("unknown tree %r" % name)
                return
            tree.unpin()
            log("UNPIN %s tree" % name)
        self.send_json({"pinned": self.pinned_versions()})

    # -- connection-experiment endpoints -----------------------------------

    def get_ping(self, query):
        self.send_json({"ok": True, "t": time.time()})

    def get_stream(self, query):
        """An endless SSE stream: a comment first, then one event every 2 s,
        until the client goes away. Chunked, so no Content-Length."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        self.close_connection = True
        n = 0
        try:
            self.chunk(": hi\n\n")
            while True:
                time.sleep(2)
                n += 1
                self.chunk('id: %d\ndata: [{"n": %d, "t": %.3f}]\n\n' % (n, n, time.time()))
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError) as exc:
            self.log_conn("STREAM ended after %d events (%s)" % (n, exc.__class__.__name__))

    def chunk(self, text):
        data = text.encode("utf-8")
        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
        self.wfile.flush()


class DevServer(ThreadingHTTPServer):
    """One listener. The handler reaches the shared trees, state and key via self.server."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, trees, state, key, tls_context=None, quiet=False):
        super().__init__(address, Handler)
        self.trees = trees  # {name: Tree}
        self.state = state
        self.key = key  # the dev key's 64 hex characters, as bytes
        self.admin_token = admin_token(key)
        self.key_fingerprint = fingerprint(key)
        self.tls_context = tls_context
        self.quiet = quiet

    def finish_request(self, request, client_address):
        # Runs in the per-connection thread, so the TLS handshake happens here
        # and a slow or bogus client never blocks the accept loop.
        if self.tls_context is None:
            Handler(request, client_address, self)
            return
        request.settimeout(Handler.timeout)
        tls = self.tls_context.wrap_socket(request, server_side=True)
        try:
            Handler(tls, client_address, self)
        finally:
            tls.close()

    def handle_error(self, request, client_address):
        """Disconnects, resets and failed handshakes are one console line, not a traceback."""
        exc = sys.exc_info()[1]
        where = "%s:%d" % client_address
        if isinstance(exc, OSError):
            log("ERROR %s  %s: %s" % (where, exc.__class__.__name__, exc))
        else:
            log("ERROR %s  unexpected exception:\n%s" % (where, traceback.format_exc()))


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------


def ensure_cert(cert_dir):
    """Generate a self-signed certificate with openssl unless one is already there."""
    os.makedirs(cert_dir, exist_ok=True)
    crt, key = os.path.join(cert_dir, "diag.crt"), os.path.join(cert_dir, "diag.key")
    if not (os.path.exists(crt) and os.path.exists(key)):
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "365",
                "-subj",
                "/CN=c4-hue-diag",
                "-keyout",
                key,
                "-out",
                crt,
            ],
            check=True,
            capture_output=True,
        )
        log("generated self-signed certificate in " + cert_dir)
    return crt, key


def write_server_file(state_dir, url, tls_url):
    """build/dev/server.json: where tools/devctl.py finds this server."""
    path = os.path.join(state_dir, "server.json")
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"url": url, "tls_url": tls_url, "pid": os.getpid(), "started": now()}, f)
    os.replace(tmp, path)
    return path


def remove_server_file(path):
    """Remove server.json if it is still this process's."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            ours = json.load(f).get("pid") == os.getpid()
        if ours:
            os.remove(path)
    except (OSError, ValueError, AttributeError):
        pass


def build_parser(default_root):
    parser = argparse.ArgumentParser(description="Dev-loop server for the hue_bridge dev build (docs/dev-loop.md).")
    parser.add_argument("--port", type=int, default=8080, help="plain HTTP port (default 8080)")
    parser.add_argument("--tls-port", type=int, default=8443, help="TLS port (default 8443)")
    parser.add_argument(
        "--bind",
        default=None,
        help="address both listeners bind (default: this VM's LAN address; 0.0.0.0 only when given here)",
    )
    parser.add_argument(
        "--key-file",
        default=None,
        help="the dev key (default $%s, else ~/.config/c4-hue-driver/devkey; created on first run)" % KEY_FILE_ENV,
    )
    parser.add_argument(
        "--ensure-key",
        action="store_true",
        help="only create the key file if missing, check it and print its path (tools/build.sh --dev)",
    )
    parser.add_argument(
        "--root", default=default_root, help="repo root, the directory containing tools/ (default: detected)"
    )
    parser.add_argument(
        "--cert-dir", default=None, help="where the self-signed certificate lives (default <root>/build/diag)"
    )
    parser.add_argument(
        "--state-dir", default=None, help="where driver.log etc. are written (default <root>/build/dev)"
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="no connection/request lines for the plain listener, no heartbeat summaries",
    )
    parser.add_argument(
        "--alpn",
        default="http/1.1",
        help="comma-separated ALPN protocols the TLS listener offers (default http/1.1). "
        "Offer 'h2,http/1.1' to learn whether a client asks for HTTP/2: the server "
        "cannot speak h2, so such a connection fails, but its OPEN line shows alpn=h2.",
    )
    return parser


def ensure_key_main(key_file):
    """--ensure-key: the path on stdout (for tools/build.sh), the rest on stderr."""
    try:
        key, created = ensure_key(key_file)
    except (DevKeyError, OSError) as exc:
        sys.exit("devserver: %s" % exc)
    sys.stderr.write("dev key %s%s, fingerprint %s\n" % (key_file, " (created)" if created else "", fingerprint(key)))
    print(key_file)


def main(argv=None):
    default_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    args = build_parser(default_root).parse_args(argv)
    key_file = os.path.abspath(os.path.expanduser(args.key_file)) if args.key_file else default_key_file()
    if args.ensure_key:
        ensure_key_main(key_file)
        return

    root = os.path.abspath(args.root)
    if not os.path.isdir(os.path.join(root, "src", "hue_bridge")):
        sys.exit("no src/hue_bridge under %s (use --root)" % root)
    cert_dir = args.cert_dir or os.path.join(root, "build", "diag")
    state_dir = args.state_dir or os.path.join(root, "build", "dev")

    try:
        key, created = ensure_key(key_file)
    except (DevKeyError, OSError) as exc:
        sys.exit("devserver: %s" % exc)
    bind = choose_bind(args.bind)
    if not bind:
        sys.exit("devserver: could not find this VM's LAN address (no default route?); pass --bind <address>")

    trees = {name: Tree(root, name) for name in TREES}
    state = State(state_dir)
    try:
        crt, cert_key = ensure_cert(cert_dir)
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.exit("could not create a certificate in %s: %s" % (cert_dir, exc))
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, cert_key)
    ctx.set_alpn_protocols([p.strip() for p in args.alpn.split(",") if p.strip()])

    plain = DevServer((bind, args.port), trees, state, key, quiet=args.quiet)
    tls = DevServer((bind, args.tls_port), trees, state, key, tls_context=ctx, quiet=args.quiet)
    url = "http://%s:%d" % (url_host(bind), plain.server_address[1])
    tls_url = "https://%s:%d" % (url_host(bind), tls.server_address[1])

    log("dev key %s%s, fingerprint %s" % (key_file, " (created)" if created else "", fingerprint(key)))
    if os.path.exists(os.path.join(root, "src", "common", KEY_MODULE)):
        log("WARNING src/common/%s exists: it is never served; delete it (tools/build.sh refuses to run)" % KEY_MODULE)
    for name in TREES:
        version, contents = trees[name].snapshot()
        log("serving %s tree: %d files from %s, version %s" % (name, len(contents), trees[name].driver, version))
    log("state in %s: %d pending command(s), next id %d" % (state_dir, len(state.commands), state.next_id))
    if bind == "0.0.0.0":
        log("WARNING listening on every address (--bind 0.0.0.0)")
    log("listening on %s and %s (Dev Server = %s:%d)" % (url, tls_url, url_host(bind), plain.server_address[1]))
    server_file = write_server_file(state_dir, url, tls_url)

    # SIGTERM (pkill) ends the server like Ctrl-C, so server.json goes too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    threading.Thread(target=tls.serve_forever, name="tls", daemon=True).start()
    try:
        plain.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        remove_server_file(server_file)
        tls.shutdown()
        tls.server_close()
        plain.server_close()


if __name__ == "__main__":
    main()
