"""The fake box's control API: what tools/fakebox.py asks of a running fake (#547, docs/fakebox-design.md §5).

Plain HTTP on 127.0.0.1 only (never another address), JSON both ways. Every request carries the header
X-Fakebox-Token with the random token of this run, which only server.json (mode 0600, in the state
directory) holds; a request without it, from another address, or with a Host other than 127.0.0.1 or
localhost (a browser led there by DNS rebinding) is refused with 403.

  GET  /boxes                     [{id, label, model, fixture, url, port, available}]
  GET  /state?box=ID[&path=a.b]   {"state": the GET /api/v1 document, "status": model.Box.status(),
                                   "faults": [...]}; with path, {"path", "value"}
  GET  /log?box=ID[&n=50]         {"entries": the last n requests, oldest first}
  POST /button  {box, window}     the button held (model event "button")
  POST /event   {box, name, args} any model event; "address" with args.port also moves the listener
  POST /fault   {box, kind, count, path, method, params}   a fault (server.FAULT_KINDS)
  POST /clear   {box, kind}       clear the faults (of one kind)
  POST /set     {box, path, value} or {box, path, unset: true}   change the document as the app would
  POST /stop                      the fake stops
`box` may be left out when the fake runs one box. Errors: 400 {"error": text}; 404 for another path.

API:
  Controller(fleet, on_change=None, on_stop=None): the commands above as methods, and
      .dispatch(method, route, query, body) -> (status, dict)
  ControlServer(controller, port=0, token=None): .start() / .stop() / .url / .token
  write_state(state_dir, info) / read_state(state_dir) / remove_state(state_dir): server.json
  Client(state_dir): .call(method, route, body=None, query=None) -> dict (ControlError on failure)
"""

import contextlib
import hmac
import json
import os
import secrets
import tempfile
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import model

STATE_FILE = "server.json"
TOKEN_HEADER = "X-Fakebox-Token"
LOOPBACK = "127.0.0.1"
MAX_BODY = 1 << 20


class ControlError(Exception):
    """The control API refused or could not be reached; the message says why."""


class Controller:
    """The control API's commands against a server.Fleet; every change runs under the box's lock."""

    def __init__(self, fleet, on_change=None, on_stop=None):
        self.fleet = fleet
        self.on_change = on_change
        self.on_stop = on_stop

    def _changed(self):
        if self.on_change:
            self.on_change()

    def boxes(self):
        out = []
        for server in self.fleet.servers:
            out.append(
                {
                    "id": server.box.box_id,
                    "label": server.label,
                    "model": server.box.model,
                    "fixture": getattr(server, "fixture", None),
                    "url": server.url,
                    "port": server.port,
                    "available": server.call(lambda box: box.available()),
                }
            )
        return out

    def state(self, box=None, path=None):
        server = self.fleet.find(box)
        if path:
            return {"path": path, "value": server.call(lambda b: b.get(path))}
        with server.lock:
            return {"state": server.box.state(), "status": server.box.status(), "faults": server.faults.listing()}

    def button(self, box=None, window=None):
        return self.event(box, "button", {} if window is None else {"window": float(window)})

    def event(self, box=None, name=None, args=None):
        if not name:
            raise ValueError("an event needs a name (%s)" % ", ".join(model.EVENTS))
        args = dict(args or {})
        server = self.fleet.find(box)
        server.call(lambda b: b.event(name, **args))
        if name == "address" and args.get("port") is not None:
            server.move(int(args["port"]))
        self._changed()
        return {"ok": True, "event": name, "status": server.call(lambda b: b.status())}

    def fault(self, box=None, kind=None, count=None, path=None, method=None, params=None):
        server = self.fleet.find(box)
        if kind in ("wrong_cert", "other_id"):
            other = (params or {}).get("id") if kind == "other_id" else None
            # Make the leaf now (openssl), not inside the first handshake.
            server.context("wrong" if kind == "wrong_cert" else "other", str(other or "0A1B2C3D4E60").upper())
        with server.lock:
            fault = server.faults.add(kind, count=count, path=path, method=method, **(params or {}))
        return {"ok": True, "fault": {k: v for k, v in fault.items() if k != "cleared"}}

    def clear(self, box=None, kind=None):
        server = self.fleet.find(box)
        with server.lock:
            return {"ok": True, "cleared": server.faults.clear(kind)}

    def set(self, box=None, path=None, value=None, unset=False):
        server = self.fleet.find(box)
        if not path:
            raise ValueError("set needs a path")
        if unset:
            server.call(lambda b: b.unset(path))
        else:
            server.call(lambda b: b.set(path, value))
        self._changed()
        return {"ok": True}

    def log(self, box=None, n=50):
        return {"entries": self.fleet.find(box).recent(n)}

    def stop(self):
        if self.on_stop:
            self.on_stop()
        return {"ok": True}

    def dispatch(self, method, route, query, body):
        """(status, answer) of one control request."""
        query = query or {}
        body = body or {}
        box = body.get("box", query.get("box"))
        try:
            if method == "GET" and route == "/boxes":
                return 200, {"boxes": self.boxes()}
            if method == "GET" and route == "/state":
                return 200, self.state(box, query.get("path"))
            if method == "GET" and route == "/log":
                return 200, self.log(box, query.get("n", 50))
            if method == "POST" and route == "/button":
                return 200, self.button(box, body.get("window"))
            if method == "POST" and route == "/event":
                return 200, self.event(box, body.get("name"), body.get("args"))
            if method == "POST" and route == "/fault":
                return 200, self.fault(
                    box, body.get("kind"), body.get("count"), body.get("path"), body.get("method"), body.get("params")
                )
            if method == "POST" and route == "/clear":
                return 200, self.clear(box, body.get("kind"))
            if method == "POST" and route == "/set":
                return 200, self.set(box, body.get("path"), body.get("value"), bool(body.get("unset")))
            if method == "POST" and route == "/stop":
                return 200, self.stop()
        except (ValueError, LookupError, TypeError) as error:
            text = error.args[0] if isinstance(error, KeyError) and error.args else str(error)
            return 400, {"error": "%s: %s" % (error.__class__.__name__, text)}
        return 404, {"error": "no such control request: %s %s" % (method, route)}


class _ControlHandler(BaseHTTPRequestHandler):
    server_version = "fakebox-control"
    sys_version = ""

    def log_message(self, format, *args):
        pass

    def version_string(self):
        return self.server_version

    def _answer(self, status, body):
        payload = json.dumps(body, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _allowed(self):
        port = self.server.server_address[1]
        host = (self.headers.get("Host") or "").strip().lower()
        if self.client_address[0] != LOOPBACK or host not in ("%s:%d" % (LOOPBACK, port), "localhost:%d" % port):
            return False
        sent = self.headers.get(TOKEN_HEADER) or ""
        return hmac.compare_digest(sent.encode("utf-8"), self.server.token.encode("utf-8"))

    def _handle(self):
        if not self._allowed():
            self._answer(403, {"error": "refused: the control API takes the token of server.json on 127.0.0.1"})
            return
        parsed = urllib.parse.urlsplit(self.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        body = {}
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            self._answer(413, {"error": "too large"})
            return
        if length:
            try:
                body = json.loads(self.rfile.read(length).decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self._answer(400, {"error": "the body is not JSON"})
                return
            if not isinstance(body, dict):
                self._answer(400, {"error": "the body is not a JSON object"})
                return
        status, answer = self.server.controller.dispatch(self.command, parsed.path, query, body)
        self._answer(status, answer)

    do_GET = do_POST = _handle


class ControlServer:
    """The control API on 127.0.0.1:`port` (0: a free one)."""

    def __init__(self, controller, port=0, token=None):
        self.controller = controller
        self.token = token or secrets.token_hex(16)
        self._httpd = ThreadingHTTPServer((LOOPBACK, int(port)), _ControlHandler)
        self._httpd.daemon_threads = True
        self._httpd.controller = controller
        self._httpd.token = self.token
        self._thread = None

    @property
    def port(self):
        return self._httpd.server_address[1]

    @property
    def url(self):
        return "http://%s:%d" % (LOOPBACK, self.port)

    def start(self):
        self._thread = threading.Thread(target=self._httpd.serve_forever, name="fakebox-control", daemon=True)
        self._thread.start()
        return self

    def stop(self):
        if self._thread is not None:
            self._httpd.shutdown()
            self._thread.join(timeout=5)
            self._thread = None
        self._httpd.server_close()


def state_path(state_dir):
    return os.path.join(state_dir, STATE_FILE)


def write_state(state_dir, info):
    """server.json, mode 0600, written whole (a temporary file renamed): it holds the control token."""
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".server-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(info, handle, indent=2, sort_keys=True)
        os.replace(tmp, state_path(state_dir))
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def read_state(state_dir):
    """server.json of the running fake; ControlError when there is none."""
    try:
        with open(state_path(state_dir), encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        raise ControlError(
            "no fake running: %s not found (start one with tools/fakebox.py serve)" % state_path(state_dir)
        ) from None
    except ValueError as error:
        raise ControlError("%s is not JSON: %s" % (state_path(state_dir), error)) from None


def remove_state(state_dir, pid=None):
    """Remove server.json (only when it is this process's, if `pid` is given)."""
    path = state_path(state_dir)
    with contextlib.suppress(OSError, ValueError):
        if pid is not None:
            with open(path, encoding="utf-8") as handle:
                if json.load(handle).get("pid") != pid:
                    return
        os.unlink(path)


class Client:
    """The CLI's side: one control request at a time to the fake whose server.json is in state_dir."""

    def __init__(self, state_dir, timeout=10.0):
        info = read_state(state_dir)
        self.url = info.get("control_url")
        self.token = info.get("token")
        self.timeout = timeout
        if not self.url or not self.token:
            raise ControlError("%s has no control_url or token" % state_path(state_dir))
        if not self.url.startswith("http://%s:" % LOOPBACK):
            raise ControlError("the control API is on 127.0.0.1 only, not %s" % self.url)

    def call(self, method, route, body=None, query=None):
        url = self.url + route
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header(TOKEN_HEADER, self.token)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # never through a proxy
        try:
            with opener.open(request, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:
            try:
                detail = json.loads(error.read().decode("utf-8")).get("error")
            except (ValueError, UnicodeDecodeError, AttributeError):
                detail = None
            raise ControlError(detail or "HTTP %d" % error.code) from None
        except (urllib.error.URLError, OSError) as error:
            raise ControlError("the fake does not answer at %s: %s" % (self.url, error)) from None
