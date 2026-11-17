"""The fake Hue Sync Box over real HTTPS (#547, docs/fakebox-design.md §2 and §5).

Each box (a model.Box) listens on its own port with the TLS leaf of fakebox/ca.py (CN=<box id>,
OU=<model>, EC P-256, under the VM's fake CA). A box serves one request at a time, as a real box does
(docs/syncbox-api-research.md (R1) §2.13): a second request waits for the first. Connections stay open
between requests (HTTP/1.1 keep-alive) until the client closes them or KEEPALIVE_S passes.

Faults (docs/fakebox-design.md §2), each until cleared or for `count` requests (connections for the
TLS ones), optionally only for one method and paths starting with `path` (after /api/v1):
  silence    the request is read and never answered; the connection is held until the client gives
             up, the fault is cleared or `hold_s` (300) passes (curl 28 on the client)
  latency    `ms` before the answer (added to any other fault)
  5xx        the answer is `status` (500) with {"code": `code` (500), "message": ...} [assumed body]
  drop       the request is read and the connection closed (TLS close_notify) with no answer (curl 52)
  truncated  the answer's headers promise the whole body, half of it is sent, the connection closes
             (curl 18)
  oversized  the answer's body is padded to `bytes` (300000) with a "padding" key, over the driver's
             256 KB limit
  redirect   `status` (302) with Location `location` (default https://<host>/redirected)
  wrong_cert a leaf of the same id from another CA (ca.ensure_wrong_box_cert): the driver's bundle
             refuses it (curl 60)
  other_id   another box behind the same address: the leaf of `id` (0A1B2C3D4E60) and that id in
             every uniqueId answered
  refuse     the port is closed: connection refused (curl 7), as while the box restarts
While the model restarts (a reboot or a firmware update) the port is closed too, and opens again when
the box answers.

Every request is logged: time, box, client, method, path, status, ms, the registration it came from,
the fault, and the request body with username, clientKey and any token replaced by <redacted>. The
Authorization header never reaches a log: a keyed request shows "auth=<redacted>". Answers are not
logged (a registration's answer holds its token). A connection that ends without a request (a TLS
handshake the client refused: the wrong_cert fault, the driver's decoy self-check) is logged as TLS.

API:
  BoxServer(box, *, port=0, bind="127.0.0.1", cert_base=None, label=None, log=print, log_file=None)
    .start() / .stop() / .url / .port / .call(fn) (fn(box) under the box's lock) / .recent(n)
    .faults.add(kind, count=None, path=None, method=None, **params) / .faults.clear(kind=None)
    .entries (the log, newest last) / .move(port)
  Fleet(servers): .start() / .stop() / .find(box_id=None)
  parse_spec("FIXTURE:ID[:PORT]") -> (fixture, id, port); make_box(fixture, id, *, fixtures, time_scale)
  random_token(id): the server's tokens (random base64; model.placeholder_token gives the Lua fake's)
"""

import base64
import collections
import json
import secrets
import select
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler

from . import ca, model

KEEPALIVE_S = 30.0  # an idle kept-alive connection is closed after this [assumed]
HANDSHAKE_S = 10.0
MAX_REQUEST_BYTES = 1 << 20
LOG_MAX = 5000
OTHER_ID = "0A1B2C3D4E60"  # the placeholder of a second box (CLAUDE.md "Licensing")
REDACTED = "<redacted>"
REDACT_KEYS = frozenset({"username", "clientKey", "accessToken", "token", "password", "appSecret"})
FAULT_KINDS = (
    "silence", "latency", "5xx", "drop", "truncated", "oversized", "redirect", "wrong_cert", "other_id", "refuse",
)  # fmt: skip
# One fault of these decides the answer; latency adds to it, other_id changes it.
TERMINAL_FAULTS = ("silence", "5xx", "drop", "truncated", "oversized", "redirect")


def redact(value):
    """A request body for the log: secrets (REDACT_KEYS) replaced, at any depth."""
    if isinstance(value, dict):
        return {k: (REDACTED if k in REDACT_KEYS else redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(v) for v in value]
    return value


def body_for_log(raw):
    """The JSON request body, redacted; text that is not JSON shows only its length (it might hold
    anything)."""
    if not raw:
        return None
    try:
        return redact(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, ValueError):
        return "<%d bytes, not JSON>" % len(raw)


class Faults:
    """The faults of one box; every method is called under the BoxServer's lock."""

    def __init__(self):
        self.items = []
        self._next = 1

    def add(self, kind, count=None, path=None, method=None, **params):
        if kind not in FAULT_KINDS:
            raise ValueError("no fault %r (have %s)" % (kind, ", ".join(FAULT_KINDS)))
        if count is not None and (not isinstance(count, int) or isinstance(count, bool) or count < 1):
            raise ValueError("a count is a whole number from 1")
        if path is not None and not str(path).startswith("/") and path != "":
            raise ValueError("a path starts with / (after /api/v1), not %r" % path)
        fault = {
            "id": self._next,
            "kind": kind,
            "count": count,
            "path": path,
            "method": method.upper() if method else None,
            "params": dict(params),
            "cleared": False,
        }
        self._next += 1
        self.items.append(fault)
        return dict(fault)

    def clear(self, kind=None):
        """Clear every fault (kind None) or those of one kind; the count cleared."""
        keep, gone = [], []
        for fault in self.items:
            (gone if kind is None or fault["kind"] == kind else keep).append(fault)
        for fault in gone:
            fault["cleared"] = True
        self.items = keep
        return len(gone)

    def listing(self):
        return [{k: v for k, v in f.items() if k != "cleared"} for f in self.items]

    def _use(self, fault):
        if fault["count"] is not None:
            fault["count"] -= 1
            if fault["count"] <= 0:
                self.items.remove(fault)
                fault["cleared"] = False  # used up, not cleared: a held silence keeps holding

    def refusing(self):
        return any(f["kind"] == "refuse" for f in self.items)

    def for_connection(self):
        """The TLS fault of a new connection: ("wrong", None), ("other", id) or ("box", None)."""
        for fault in list(self.items):
            if fault["kind"] == "wrong_cert":
                self._use(fault)
                return "wrong", None
        for fault in self.items:
            if fault["kind"] == "other_id":
                return "other", str(fault["params"].get("id", OTHER_ID)).upper()
        return "box", None

    def for_request(self, method, resource):
        """(latency ms, the terminal fault or None, the other_id fault or None) for one request."""

        def matches(fault):
            if fault["method"] and fault["method"] != method:
                return False
            return fault["path"] is None or (resource is not None and resource.startswith(fault["path"]))

        latency, terminal, other = 0.0, None, None
        for fault in list(self.items):
            if not matches(fault):
                continue
            if fault["kind"] == "latency":
                latency += float(fault["params"].get("ms", 1000))
                self._use(fault)
            elif fault["kind"] in TERMINAL_FAULTS and terminal is None:
                terminal = fault
                self._use(fault)
            elif fault["kind"] == "other_id" and other is None:
                other = fault
                self._use(fault)
        return latency, terminal, other


class _Abort(Exception):
    """End the connection now, with no (more) answer."""


class _Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fakebox"
    sys_version = ""
    timeout = KEEPALIVE_S
    which = "box"  # the certificate this connection got: box, wrong or other

    def log_message(self, format, *args):
        pass  # every request is logged by _serve

    def version_string(self):
        return self.server_version

    def setup(self):
        super().setup()
        self.served = 0

    def handle(self):
        error = None
        try:
            super().handle()
        except _Abort:
            self.close_connection = True
            self._close_notify()
            return
        except (ssl.SSLError, ConnectionError, TimeoutError, OSError) as exc:
            self.close_connection = True
            error = exc
        if not self.served:
            # No request on this connection. Under TLS 1.3 a client that refuses the certificate (curl
            # 60: the wrong CA, the driver's decoy self-check) does so after the server's handshake.
            self.server.record_tls(self.client_address, self.which, error, after_handshake=True)

    def _close_notify(self):
        """A deliberate close (drop, truncated, silence): TLS close_notify, then the socket goes, so the
        client sees the connection end cleanly (curl 52 for no answer, 18 for a cut body)."""
        try:
            self.connection.settimeout(1.0)
            self.connection.unwrap()
        except (ssl.SSLError, OSError, ValueError):
            pass

    def finish(self):
        try:
            super().finish()
        except (ConnectionError, ssl.SSLError, OSError):
            pass

    def do_GET(self):
        self._serve()

    do_PUT = do_POST = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_GET

    def _client_gone(self):
        sock = self.connection
        try:
            readable, _, _ = select.select([sock], [], [], 0)
        except (OSError, ValueError):
            return True
        if not readable:
            return False
        try:
            sock.setblocking(False)
            return sock.recv(1) == b""
        except ssl.SSLWantReadError:
            return False
        except (ssl.SSLError, OSError):
            return True
        finally:
            try:
                sock.settimeout(self.timeout)
            except OSError:
                pass

    def _send(self, status, payload, headers=(), truncate=False):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command == "HEAD":
            return
        if truncate:
            self.wfile.write(payload[: max(1, len(payload) // 2)])
            self.wfile.flush()
            raise _Abort()
        self.wfile.write(payload)

    def _serve(self):
        bs = self.server
        self.served += 1
        started = time.monotonic()
        method = self.command
        length = self.headers.get("Content-Length")
        raw = b""
        if length:
            try:
                n = int(length)
            except ValueError:
                n = -1
            if n < 0 or n > MAX_REQUEST_BYTES:
                self.close_connection = True
                self._send(413, b'{"code":12,"message":"Request too large"}')
                bs.record(self, method, None, 413, started, raw, None)
                return
            raw = self.rfile.read(n)
        resource = model.Box.resource(self.path)
        headers = dict(self.headers.items())
        status, fault_kind, who = None, None, None
        try:
            with bs.serve_lock:
                with bs.lock:
                    latency, terminal, other = bs.faults.for_request(method, resource)
                    who = bs.box_registration(headers)
                fault_kind = terminal["kind"] if terminal else ("latency" if latency else None)
                if other is not None:
                    fault_kind = "other_id" if fault_kind is None else fault_kind + "+other_id"
                if latency:
                    time.sleep(latency / 1000.0)
                if terminal and terminal["kind"] == "silence":
                    self._hold(bs, terminal)
                if terminal and terminal["kind"] == "drop":
                    raise _Abort()
                with bs.lock:
                    status, body = bs.box.request(method, self.path, headers, raw or None)
                if status is None:  # restarting: nothing answers
                    raise _Abort()
                extra = []
                if other is not None:
                    body = _swap_id(body, str(other["params"].get("id", OTHER_ID)).upper())
                kind = terminal["kind"] if terminal else None
                if kind == "5xx":
                    status = int(terminal["params"].get("status", 500))
                    body = {"code": int(terminal["params"].get("code", 500)), "message": "Internal Server Error"}
                elif kind == "redirect":
                    status = int(terminal["params"].get("status", 302))
                    host = self.headers.get("Host") or "%s:%d" % (bs.bind, bs.port)
                    extra.append(("Location", terminal["params"].get("location") or "https://%s/redirected" % host))
                    body = {}
                payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
                if kind == "oversized":
                    size = int(terminal["params"].get("bytes", 300000))
                    padded = dict(body) if isinstance(body, dict) else {"body": body}
                    padded["padding"] = ""
                    base = len(json.dumps(padded, separators=(",", ":")).encode("utf-8"))
                    padded["padding"] = "x" * max(0, size - base)
                    payload = json.dumps(padded, separators=(",", ":")).encode("utf-8")
                self._send(status, payload, extra, truncate=kind == "truncated")
        except _Abort:
            self.close_connection = True
            answered = status if fault_kind == "truncated" else None
            bs.record(self, method, resource, answered, started, raw, fault_kind, who)
            raise
        bs.record(self, method, resource, status, started, raw, fault_kind, who)

    def _hold(self, bs, fault):
        """silence: no answer until the client gives up, the fault is cleared or hold_s passes."""
        deadline = time.monotonic() + float(fault["params"].get("hold_s", 300))
        while time.monotonic() < deadline and not bs.stopping.is_set():
            with bs.lock:
                if fault["cleared"]:
                    break
            if self._client_gone():
                break
            time.sleep(0.05)
        raise _Abort()


def _swap_id(body, other):
    """other_id: the id of another box wherever an answer names the box's own."""
    if not isinstance(body, dict):
        return body
    body = dict(body)
    if "uniqueId" in body:
        body["uniqueId"] = other
    if isinstance(body.get("device"), dict) and "uniqueId" in body["device"]:
        body["device"] = dict(body["device"], uniqueId=other)
    return body


class BoxServer:
    """One box on one port (see the module's text)."""

    def __init__(self, box, *, port=0, bind="127.0.0.1", cert_base=None, label=None, log=print, log_file=None):
        self.box = box
        self.bind = bind
        self.port = int(port)
        self.cert_base = cert_base
        self.label = label or box.box_id
        self.log = log
        self.log_file = log_file
        self.lock = threading.RLock()  # the model's and the faults'
        self.serve_lock = threading.Lock()  # one request at a time (R1 §2.13)
        self.faults = Faults()
        self.entries = collections.deque(maxlen=LOG_MAX)
        self.stopping = threading.Event()
        self._contexts = {}
        self._context_lock = threading.Lock()
        self._listener = None
        self._thread = None
        self._workers = set()
        self._conns = set()
        self._workers_lock = threading.Lock()
        self._log_lock = threading.Lock()

    # -- TLS ---------------------------------------------------------------------------------------

    def context(self, which="box", other_id=None):
        """The server context with the box's leaf, the wrong CA's (wrong_cert) or another id's."""
        key = (which, other_id)
        with self._context_lock:
            if key not in self._contexts:
                device_type = self.box.model or "HSB2"
                if which == "wrong":
                    cert, keyfile = ca.ensure_wrong_box_cert(self.box.box_id, device_type, base=self.cert_base)
                else:
                    cert, keyfile = ca.ensure_box_cert(other_id or self.box.box_id, device_type, base=self.cert_base)
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                ctx.minimum_version = ssl.TLSVersion.TLSv1_2
                ctx.load_cert_chain(cert, keyfile)
                self._contexts[key] = ctx
            return self._contexts[key]

    # -- running -----------------------------------------------------------------------------------

    @property
    def url(self):
        host = "127.0.0.1" if self.bind in ("0.0.0.0", "") else self.bind
        return "https://%s:%d/api/v1" % (host, self.port)

    def start(self):
        self.context()  # the leaf now, so a CA problem stops the start
        self._open()
        self._thread = threading.Thread(target=self._accept_loop, name="fakebox-%s" % self.label, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        self.stopping.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None
        self._close()
        with self._workers_lock:
            workers, conns = list(self._workers), list(self._conns)
        for conn in conns:  # a kept-alive connection waiting for its next request ends now
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        for worker in workers:
            worker.join(timeout=2)

    def move(self, port):
        """Listen on another port (an address change the e2e harness models as a port change)."""
        with self.lock:
            self._close()
            self.port = int(port)
            self._open()

    def call(self, fn):
        """fn(box) under the box's lock (the control API's way in)."""
        with self.lock:
            return fn(self.box)

    def recent(self, n=50):
        """The last n log entries, oldest first."""
        with self._log_lock:
            return list(self.entries)[-max(1, int(n)) :]

    def box_registration(self, headers):
        """The registration a request's token belongs to, for the log (never the token)."""
        keyed, token = model.bearer(headers)
        if not keyed:
            return None
        return self.box.owner(token) or "unknown"

    def _open(self):
        if self._listener is not None:
            return
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((self.bind, self.port))
            sock.listen(16)
        except OSError:
            sock.close()
            raise
        self.port = sock.getsockname()[1]
        self._listener = sock

    def _close(self):
        sock, self._listener = self._listener, None
        if sock is not None:
            sock.close()

    def _accept_loop(self):
        while not self.stopping.is_set():
            with self.lock:
                up = self.box.available() and not self.faults.refusing()
            if not up:
                if self._listener is not None:
                    self._close()
                    why = "refuse" if self.box.available() else "restarting"
                    self._say("%s: port %d closed (%s)" % (self.label, self.port, why))
                self.stopping.wait(0.05)
                continue
            if self._listener is None:
                try:
                    self._open()
                    self._say("%s: port %d open" % (self.label, self.port))
                except OSError as error:
                    self._say("%s: cannot listen on %d again: %s" % (self.label, self.port, error))
                    self.stopping.wait(0.5)
                    continue
            listener = self._listener
            try:
                readable, _, _ = select.select([listener], [], [], 0.05)
            except (OSError, ValueError):
                continue
            if not readable:
                continue
            try:
                raw, addr = listener.accept()
            except OSError:
                continue
            worker = threading.Thread(target=self._connection, args=(raw, addr), daemon=True)
            with self._workers_lock:
                self._workers.add(worker)
            worker.start()

    def _connection(self, raw, addr):
        try:
            with self.lock:
                which, other_id = self.faults.for_connection()
            raw.settimeout(HANDSHAKE_S)
            try:
                conn = self.context(which, other_id).wrap_socket(raw, server_side=True)
            except (ssl.SSLError, OSError) as error:
                self.record_tls(addr, which, error)
                raw.close()
                return
            with self._workers_lock:
                self._conns.add(conn)
            try:
                if not self.stopping.is_set():
                    # The connection's certificate, for a handler whose first read fails (record_tls).
                    handler = type("_ConnectionHandler", (_Handler,), {"which": which})
                    handler(conn, addr, self)
            finally:
                with self._workers_lock:
                    self._conns.discard(conn)
                try:
                    conn.close()
                except OSError:
                    pass
        finally:
            with self._workers_lock:
                self._workers.discard(threading.current_thread())

    # -- the log -----------------------------------------------------------------------------------

    def _say(self, text):
        if self.log:
            self.log(text)

    def _write(self, entry, line):
        with self._log_lock:
            self.entries.append(entry)
            if self.log_file:
                with open(self.log_file, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(entry, sort_keys=True) + "\n")
        self._say(line)

    def record_tls(self, addr, which, error, after_handshake=False):
        entry = {
            "time": _stamp(),
            "box": self.box.box_id,
            "client": addr[0],
            "method": "TLS",
            "path": None,
            "status": None,
            "ms": 0,
            "fault": {"wrong": "wrong_cert", "other": "other_id"}.get(which),
            "note": "%s: %s"
            % (
                "no request after the handshake" if after_handshake else "handshake failed",
                (getattr(error, "reason", None) or error.__class__.__name__) if error is not None else "closed",
            ),
        }
        self._write(entry, "%s %s %s TLS %s" % (entry["time"], self.label, addr[0], entry["note"]))

    def record(self, handler, method, resource, status, started, raw, fault, who=None):
        ms = int(round((time.monotonic() - started) * 1000))
        path = handler.path.split("?", 1)[0]
        entry = {
            "time": _stamp(),
            "box": self.box.box_id,
            "client": handler.client_address[0],
            "method": method,
            "path": path,
            "status": status,
            "ms": ms,
            "keyed": handler.headers.get("Authorization") is not None,
            "registration": who,
            "fault": fault,
            "body": body_for_log(raw),
        }
        parts = [entry["time"], self.label, entry["client"], method, path, str(status or "-"), "%dms" % ms]
        if entry["keyed"]:
            parts.append("auth=%s reg=%s" % (REDACTED, who))
        if entry["body"] is not None:
            parts.append(json.dumps(entry["body"], separators=(",", ":"), sort_keys=True))
        if fault:
            parts.append("[%s]" % fault)
        self._write(entry, " ".join(parts))


def _stamp():
    now = time.time()
    return time.strftime("%H:%M:%S", time.localtime(now)) + ".%03d" % int((now % 1) * 1000)


class Fleet:
    """Several boxes, each on its own port."""

    def __init__(self, servers):
        self.servers = list(servers)

    def start(self):
        started = []
        try:
            for server in self.servers:
                started.append(server.start())
        except BaseException:
            for server in started:
                server.stop()
            raise
        return self

    def stop(self):
        for server in self.servers:
            server.stop()

    def find(self, box_id=None):
        """The box of this id (or label), or the only box when none is named; LookupError otherwise."""
        if box_id is None:
            if len(self.servers) == 1:
                return self.servers[0]
            raise LookupError("several boxes: name one (%s)" % ", ".join(s.box.box_id for s in self.servers))
        for server in self.servers:
            if str(box_id).upper() in (server.box.box_id, str(server.label).upper()):
                return server
        raise LookupError("no box %s (have %s)" % (box_id, ", ".join(s.box.box_id for s in self.servers)))


def random_token(registration_id):
    """A token as a box's looks (base64 text, R1 §2.1), random: the server's, never logged."""
    del registration_id
    return base64.b64encode(secrets.token_bytes(30)).decode("ascii")


def make_box(fixture, box_id, *, fixtures, time_scale=1.0, address=None, token_factory=random_token, **options):
    """A model.Box for the server: the fixture's state under this id, on a ScaledClock."""
    clock = model.ScaledClock(time_scale)
    return model.Box(
        fixture, clock, box_id=box_id, address=address, fixtures=fixtures, token_factory=token_factory, **options
    )


def parse_spec(spec):
    """FIXTURE:ID[:PORT] (the --box of tools/fakebox.py serve) -> (fixture, id, port or None)."""
    parts = str(spec).split(":")
    if len(parts) not in (2, 3) or not parts[0] or not parts[1]:
        raise ValueError("a box is FIXTURE:ID[:PORT], like HSB2:0A1B2C3D4E5F, not %r" % spec)
    if not ca.BOX_ID_RE.match(parts[1]):
        raise ValueError("a box id is 12 hex digits, not %r" % parts[1])
    port = None
    if len(parts) == 3:
        if not parts[2].isdigit() or not 0 <= int(parts[2]) < 65536:
            raise ValueError("a port is 0 (any free one) to 65535, not %r" % parts[2])
        port = int(parts[2])
    return parts[0], parts[1].upper(), port
