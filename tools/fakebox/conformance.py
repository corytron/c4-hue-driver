#!/usr/bin/env python3
"""The rules of docs/syncbox-behaviour.md checked against a real Hue Play HDMI Sync Box (#547).

Both fake boxes (tools/fakebox/model.py and the Lua fake) keep the rules of docs/syncbox-behaviour.md;
57 of them were [assumed]. This probe settles every one it can from this VM with no hands, against the
owner's box, in one run of a few minutes, and walks the owner through the few that need a physical
action (§16 of that document lists them: table A the probe's, table B the hands-on steps, table C
those no one can practically test).

  register --address A [--twice]
      POST /api/v1/registrations (appName c4-hue-probe, instanceName conformance) once a second for
      up to 60 s while the owner holds the box's button (about 3 s, until the LED blinks green). Right
      after a registration it posts once more, which must be refused (one registration per press,
      SB82). --twice then waits for a second press and registers again under the same names (SB85,
      SB86). The tokens go to ~/.config/c4-hue-driver/fakebox/probe.json (mode 0600), never to the
      screen, a log or a report.
  run --address A [--only SB2 SB42 ...] [--report PATH]
      Proves the box's identity, snapshots its whole state, runs every check that needs no hands and
      is safe, restores the snapshot's settings after each step and everything at the end, verifies the
      restore by reading the box again, and writes the report (Markdown) and the redacted answers as
      candidate fixtures.
  hands --address A --step N [--input inputK]
      Hands-on step N (2 to 5; step 1 is `register --twice`): sets the box up, says what to do, reads
      the box meanwhile, records the verdicts and restores the box. `hands --list` prints the steps.
  forget --address A
      DELETE the probe's own registrations (each with its own token) and remove probe.json's entry.
  report
      Writes the report again from the last run and the hands-on steps.

VISIBLE CHANGES. `run` and `hands` switch the box between powersave, passthrough and the three sync
modes, change inputs, areas, brightness and intensities: the lights and the TV picture change while it
runs. Everything it changed is put back at the end and checked.

Identity before any token: TLS pinned to Signify's root src/hue_syncbox/certs/hsb_ca.pem (the chain is
verified, the host name is not: a box's leaf names its id, not its address), then the unkeyed GET
/api/v1/device, whose uniqueId must be the leaf's common name, as syncbox/identity.lua does; a box
already registered must also be the one probe.json names. Only then does a token leave this VM.

Never sent: PUT /hue with a bridge (bridgeUniqueId, username, clientKey); a device action, update or
bluetooth change (no restart, no firmware); anything under /ir or /presets but a GET; a DELETE of a
registration the box lists that is not the probe's own; a behavior key the box lacks, except the one
SB62 probe of a key of another model with the value 0 (off). A guard refuses each of these before it
reaches the network.

Pace: one request at a time on one kept-alive connection, at least 250 ms apart; HTTP 503, and code 16
on a request that prepares a check, are retried after 1, 2 and 4 s; the run stops starting checks
after its time budget (290 s) and still restores.

Privacy: the box's address and id, the bridge's, the Wi-Fi name, every name in the state and every
token are replaced in everything written (placeholders 10.0.2.150, 0A1B2C3D4E5F, 10.0.2.143,
001788fffe123abc; generic names); keys, tokens and secrets read "<redacted>". Files go to
build/conformance/ (gitignored): report.md, run.json, hands.json, fixtures/*.json.

Test options (tools/tests/test_fakebox_conformance.py runs the probe against the Python fake box):
--cafile trusts another root (the fake's CA), --probe-file and --out move the files, --pace-ms 0.

Exit codes: 0 done (a contradicted rule is a finding, not a failure), 1 the probe could not run
(identity, TLS, no registration, a refused restore), 2 usage, 130 interrupted. Standard library only;
runs under python3 -I.
"""

import argparse
import copy
import datetime
import http.client
import json
import os
import re
import ssl
import sys
import tempfile
import time

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
DEFAULT_CAFILE = os.path.join(ROOT, "src", "hue_syncbox", "certs", "hsb_ca.pem")
BEHAVIOUR = os.path.join(ROOT, "docs", "syncbox-behaviour.md")
DEFAULT_OUT = os.path.join(ROOT, "build", "conformance")
DEFAULT_PROBE_FILE = os.path.join(os.path.expanduser("~"), ".config", "c4-hue-driver", "fakebox", "probe.json")

APP_NAME = "c4-hue-probe"
INSTANCE_NAME = "conformance"
WRONG_TOKEN = "WRONG-TOKEN-NOT-REAL"
PACE_S = 0.25
TIMEOUT_S = 10.0
BUDGET_S = 290.0
REGISTER_WAIT_S = 60.0
REGISTER_EVERY_S = 1.0
SETTLE_S = 8.0  # a sync start reaching the bridge, a stream moving
STEADY_S = 1.0  # how long "nothing changes" is watched
POLL_S = 0.5
HANDS_WAIT_S = 180.0  # an owner's physical action, relayed
RESTART_SILENCE_S = (15.0, 45.0)  # SB120's 30 s, give or take half
BACKOFF_S = (1.0, 2.0, 4.0)

SYNC_MODES = ("video", "game", "music")
SYNC_CYCLE = ("video", "music", "game")  # SB38
INTENSITIES = ("subtle", "moderate", "high", "intense")
CONNECTION_STATES = (
    "uninitialized", "disconnected", "connecting", "unauthorized", "connected", "invalidgroup", "streaming", "busy",
)  # fmt: skip
CODE_STATUS = {2: 401, 10: 404, 12: 400, 13: 400, 15: 400, 16: 400}  # SB10
# Model-specific behavior keys (SB62): a key another model has, sent only with 0 (off) to see it refused.
SB62_CANDIDATES = ("forceDoviNative", "usbPowersave", "hpdInputSwitch", "soloMode")
VOLATILE = frozenset({"lastUsed", "temperature", "strength", "lastCheckedUpdate"})

PLACEHOLDER_ID = "0A1B2C3D4E5F"
PLACEHOLDER_OTHER_ID = "0A1B2C3D4E60"
PLACEHOLDER_ADDRESS = "10.0.2.150"
PLACEHOLDER_BRIDGE_ADDRESS = "10.0.2.143"
PLACEHOLDER_BRIDGE_ID = "001788fffe123abc"
PLACEHOLDERS = frozenset({PLACEHOLDER_ADDRESS, PLACEHOLDER_BRIDGE_ADDRESS, "192.0.2.7"})
REDACTED = "<redacted>"
SAFE_APP_NAMES = frozenset({"huesync", "hue sync", "philips hue", "c4-hue", APP_NAME})

# Why a rule is not checked by `run` (shown in the report when nothing else settled it).
HANDS = {
    "SB56": "its refusal by state needs the bridge link down: hands-on step 4",
    "SB63": "the event half: hands-on step 2",
    "SB70": "a source sending CEC Active Source: hands-on step 2",
    "SB71": "a source plugged in: hands-on step 3",
    "SB73": "a link appearing: hands-on step 2",
    "SB74": "a source going off while syncing: hands-on step 2",
    "SB78": "an input of each kind (linked and not): hands-on step 2",
    "SB82": "a button press: hands-on step 1 (register)",
    "SB85": "a second press: hands-on step 1 (register --twice)",
    "SB86": "another registration's token needs the second press of hands-on step 1",
    "SB91": "the bridge link down: hands-on step 4",
    "SB93": "the bridge link down while syncing: hands-on step 4",
    "SB120": "a restart: hands-on step 5",
}
NOT_PROBED = {
    "SB64": "what the two flags do is the fakes' convention",
    "SB72": "needs an input that reads linked; hands-on step 2 reads it too",
    "SB75": "needs the TV's CEC standby; shown by its sources",
    "SB76": "needs the TV's USB power to drop; shown by its sources",
    "SB77": "needs inactivePowersave minutes of idle time; shown by its sources",
    "SB83": "a convention of the fakes",
    "SB87": "needs a registration deleted in the Hue Sync app; shown by its sources",
    "SB92": "needs another app streaming to the bridge; shown by its sources",
    "SB95": "the refusal is for a box below API level 10: table C",
    "SB96": "a convention of the fakes; the probe never sends a bridge change",
    "SB97": "the box runs with a bridge: table C",
    "SB98": "needs the link in invalidgroup; shown by its sources",
    "SB112": "needs a rename in the Hue Sync app; shown by its sources",
    "SB114": "needs the router to move the box: table C",
    "SB121": "needs a firmware update: table C",
    "SB122": "needs a firmware update that raises the API level: table C",
}


class ProbeError(Exception):
    """The probe cannot go on (identity, TLS, no registration, a guard): exit 1."""


class Precondition(Exception):
    """A check's setup failed: its rules read "not checked" with this reason."""


# -- small helpers ------------------------------------------------------------------------------------


def dig(node, path, default=None):
    """The value at a dotted path, or default."""
    for part in [p for p in str(path).split(".") if p]:
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            return default
    return node


def mode_of(state):
    return dig(state, "execution.mode")


def inputs_of(state):
    hdmi = (state or {}).get("hdmi") or {}
    names = [k for k in hdmi if re.fullmatch(r"input\d+", k) and isinstance(hdmi[k], dict)]
    return sorted(names, key=lambda k: int(k[5:]))


def similar(a, b):
    """Equal, but for the volatile keys (lastUsed, temperature, ...)."""
    if isinstance(a, dict) and isinstance(b, dict):
        keys = set(a) | set(b)
        return all(k in VOLATILE or (k in a and k in b and similar(a[k], b[k])) for k in keys)
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    return a == b


def other_intensity(current):
    """An intensity two steps from `current` (never a neighbour a cycle could reach by accident)."""
    if current in INTENSITIES:
        return INTENSITIES[(INTENSITIES.index(current) + 2) % len(INTENSITIES)]
    return "moderate"


def cycle(values, current, direction):
    values = list(values)
    if current not in values:
        return values[0]
    return values[(values.index(current) + (1 if direction == "next" else -1)) % len(values)]


def describe(method, path, body=None, raw=None):
    text = "%s /api/v1%s" % (method, path)
    if raw is not None:
        text += " (a body that is not JSON)"
    elif body is not None:
        text += " " + json.dumps(body, sort_keys=True, separators=(",", ":"))
    return text


def iso_now():
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def split_address(address, port=None):
    """host[:port] -> (host, port); the port defaults to 443."""
    host, sep, rest = str(address).rpartition(":")
    if sep and rest.isdigit() and host and ":" not in host:
        return host, int(rest)
    return str(address), int(port or 443)


# -- privacy -----------------------------------------------------------------------------------------

SECRET_KEY_RE = re.compile(r"(token|secret|passw|username|psk|(^|[a-z])key$)", re.I)
IPV4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
MAC_RE = re.compile(r"\b[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}\b")
UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
NAME_KEYS = frozenset({"name", "instanceName", "ssid"})
# Words of the protocol that a user's name might also be: never replaced inside the probe's own text.
PROTOCOL_WORDS = frozenset(
    {"video", "game", "music", "passthrough", "powersave", "linked", "plugged", "unplugged", "output", "input"}
)


class Redactor:
    """Replaces what identifies the house in anything the probe writes (see the module's text)."""

    def __init__(self):
        self.exact = {}  # sensitive text -> placeholder (ids, addresses, names, tokens)
        self.names = {}  # a name -> its generic name (replaced at word boundaries)
        self._uuids = {}
        self._apps = {}

    def secret(self, value):
        if isinstance(value, str) and value:
            self.exact[value] = REDACTED

    def _map(self, value, placeholder):
        if isinstance(value, str) and value and value not in PLACEHOLDERS:
            self.exact.setdefault(value, placeholder)
            if value.upper() != value:
                self.exact.setdefault(value.upper(), placeholder)
            if value.lower() != value:
                self.exact.setdefault(value.lower(), placeholder)

    def _name(self, value, generic):
        if isinstance(value, str) and value.strip() and value not in self.names:
            self.names[value] = generic

    def learn(self, state, address=None, box_id=None):
        """Every identifying value of a GET /api/v1 (or GET /device) answer and the address used."""
        state = state if isinstance(state, dict) else {}
        device = state.get("device") if isinstance(state.get("device"), dict) else state
        if address:
            self._map(address, PLACEHOLDER_ADDRESS)
        self._map(box_id, PLACEHOLDER_ID)
        self._map(device.get("uniqueId"), PLACEHOLDER_ID)
        self._map(device.get("ipAddress"), PLACEHOLDER_ADDRESS)
        self._name(device.get("name"), "Sync Box")
        self._name(dig(device, "wifi.ssid"), "ExampleNet")
        hue = state.get("hue") if isinstance(state.get("hue"), dict) else {}
        self._map(hue.get("bridgeUniqueId"), PLACEHOLDER_BRIDGE_ID)
        self._map(hue.get("bridgeIpAddress"), PLACEHOLDER_BRIDGE_ADDRESS)
        for n, (gid, group) in enumerate(sorted((hue.get("groups") or {}).items()), 1):
            self._uuid(gid)
            if isinstance(group, dict):
                self._name(group.get("name"), "Area %d" % n)
        hdmi = state.get("hdmi") if isinstance(state.get("hdmi"), dict) else {}
        for port, info in hdmi.items():
            if isinstance(info, dict):
                generic = "TV" if port == "output" else "HDMI %s" % port[5:]
                self._name(info.get("name"), generic)
        regs = state.get("registrations") if isinstance(state.get("registrations"), dict) else {}
        for n, (_, reg) in enumerate(sorted(regs.items()), 1):
            if isinstance(reg, dict):
                if reg.get("instanceName") != INSTANCE_NAME:
                    self._name(reg.get("instanceName"), "Instance %d" % n)
                self._app(reg.get("appName"))
        for section, label in (("presets", "Preset"),):
            for n, (_, item) in enumerate(sorted((state.get(section) or {}).items()), 1):
                if isinstance(item, dict):
                    self._name(item.get("name"), "%s %d" % (label, n))
        for n, (_, code) in enumerate(sorted((dig(state, "ir.codes") or {}).items()), 1):
            if isinstance(code, dict):
                self._name(code.get("name"), "Code %d" % n)

    def _uuid(self, value):
        if isinstance(value, str) and UUID_RE.fullmatch(value) and value.lower() not in self._uuids:
            self._uuids[value.lower()] = "6a7b8c9d-0000-4000-8000-0000000ea%03d" % (len(self._uuids) + 1)
        return self._uuids.get(str(value).lower())

    def _app(self, value):
        if isinstance(value, str) and value.lower() not in SAFE_APP_NAMES and value not in self._apps:
            self._apps[value] = "App %d" % (len(self._apps) + 1)
            self.names[value] = self._apps[value]

    def text(self, value):
        """A string with every known value replaced, then any address, MAC, UUID left."""
        if not isinstance(value, str):
            return value
        for key in sorted(self.exact, key=len, reverse=True):
            if key in value:
                value = value.replace(key, self.exact[key])
        for name in sorted(self.names, key=len, reverse=True):
            if len(name) >= 3 and name.lower() not in PROTOCOL_WORDS and name in value:
                value = re.sub(r"(?<!\w)%s(?!\w)" % re.escape(name), lambda _m, n=name: self.names[n], value)
        value = UUID_RE.sub(lambda m: self._uuid(m.group(0)), value)
        value = IPV4_RE.sub(lambda m: m.group(0) if m.group(0) in PLACEHOLDERS else PLACEHOLDER_ADDRESS, value)
        return MAC_RE.sub("02:00:00:00:00:00", value)

    def json(self, value, key=None):
        """A copy of a decoded answer: secrets "<redacted>", names generic, the rest through text()."""
        if isinstance(value, dict):
            out = {}
            for k, v in value.items():
                nk = self.text(k) if isinstance(k, str) else k
                if isinstance(k, str) and SECRET_KEY_RE.search(k) and isinstance(v, (str, int, float)):
                    out[nk] = REDACTED
                else:
                    out[nk] = self.json(v, k)
            return out
        if isinstance(value, list):
            return [self.json(v, key) for v in value]
        if isinstance(value, str):
            if key in NAME_KEYS and value not in self.names and value != INSTANCE_NAME and value.strip():
                return "Name"
            if key == "appName" and value in self.names:
                return self.names[value]
            return self.text(value)
        return value


# -- the connection ----------------------------------------------------------------------------------


class Answer:
    """One answer: status (None when none came), the decoded body, its text, and why none came."""

    __slots__ = ("status", "body", "text", "error")

    def __init__(self, status, body=None, text="", error=None):
        self.status, self.body, self.text, self.error = status, body, text, error

    @property
    def code(self):
        return self.body.get("code") if isinstance(self.body, dict) else None


def pinned_context(cafile):
    """TLS that trusts only `cafile`'s roots and checks the chain, not the host name (a box's leaf names
    its id). X.509 strict mode is off, as for curl in Director."""
    if not os.path.isfile(cafile):
        raise ProbeError("no root certificate at %s" % cafile)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_verify_locations(cafile)
    ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
    return ctx


class BoxClient:
    """One kept-alive HTTPS connection to the box, one request at a time, paced. Every new connection's
    leaf must name the expected id once one is known."""

    def __init__(
        self, host, port=443, cafile=DEFAULT_CAFILE, pace_s=PACE_S, timeout_s=TIMEOUT_S, sleep=None, clock=None
    ):
        self.host, self.port = host, int(port)
        self.context = pinned_context(cafile)
        self.pace_s, self.timeout_s = pace_s, timeout_s
        self.sleep = sleep or time.sleep
        self.clock = clock or time.monotonic
        self.expected_id = None
        self.peer = {}
        self.count = 0
        self.observers = []
        self._conn = None
        self._last = None

    def close(self):
        conn, self._conn = self._conn, None
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass

    def _pace(self):
        if self._last is not None:
            wait = self._last + self.pace_s - self.clock()
            if wait > 0:
                self.sleep(wait)

    def _connect(self):
        conn = http.client.HTTPSConnection(self.host, self.port, context=self.context, timeout=self.timeout_s)
        try:
            conn.connect()
        except ssl.SSLCertVerificationError as error:
            conn.close()
            raise ProbeError(
                "the certificate at the box's address does not chain to the pinned root (%s)"
                % (error.verify_message or "verify failed")
            ) from None
        cert = conn.sock.getpeercert() or {}
        subject = {}
        for rdn in cert.get("subject", ()):
            for name, value in rdn:
                subject[name] = value
        self.peer = {"cn": subject.get("commonName"), "ou": subject.get("organizationalUnitName")}
        if self.expected_id and str(self.peer["cn"] or "").upper() != self.expected_id:
            conn.close()
            raise ProbeError("the certificate at the box's address names another box than the one expected")
        self._conn = conn

    def handshake(self):
        """Connect (if not connected) and return the leaf's common name and unit."""
        if self._conn is None:
            self._pace()
            try:
                self._connect()
            finally:
                self._last = self.clock()
        return dict(self.peer)

    def request(self, method, path, body=None, token=None, raw=None):
        """method /api/v1<path>; body JSON (or raw text); token a Bearer token or None. An Answer."""
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        data = None
        if raw is not None:
            data = raw.encode("utf-8")
        elif body is not None:
            data = json.dumps(body).encode("utf-8")
        if data is not None:
            headers["Content-Type"] = "application/json"
        answer = None
        for attempt in range(len(BACKOFF_S) + 1):
            answer = self._once(method, "/api/v1" + path, headers, data)
            if answer.status == 503 and attempt < len(BACKOFF_S):
                self.sleep(BACKOFF_S[attempt])
                continue
            break
        for observer in self.observers:
            observer(method, path, body, answer)
        return answer

    def _once(self, method, url, headers, data, retried=False):
        self._pace()
        reused = self._conn is not None
        try:
            if self._conn is None:
                self._connect()
            self._conn.request(method, url, body=data, headers=headers)
            response = self._conn.getresponse()
            payload = response.read()
            status = response.status
            if response.will_close:
                self.close()
        except ProbeError:
            raise
        except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError) as error:
            self.close()
            if reused and not retried:  # a kept-alive connection the box had closed: once more, fresh
                return self._once(method, url, headers, data, retried=True)
            return Answer(None, error=type(error).__name__)
        except (OSError, http.client.HTTPException) as error:
            self.close()
            return Answer(None, error=type(error).__name__)
        finally:
            self._last = self.clock()
        self.count += 1
        text = payload.decode("utf-8", "replace")
        try:
            body = json.loads(text) if text.strip() else None
        except ValueError:
            body = None
        return Answer(status, body, text)


# -- the probe's own files ----------------------------------------------------------------------------


def _write_private(path, data):
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=1, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


class Store:
    """probe.json: {"version": 1, "boxes": {ID: {"registration", "token", "second": {...}, "created"}}}."""

    def __init__(self, path=DEFAULT_PROBE_FILE):
        self.path = path

    def load(self):
        try:
            with open(self.path, encoding="utf-8") as handle:
                data = json.load(handle)
        except FileNotFoundError:
            return {"version": 1, "boxes": {}}
        except ValueError as error:
            raise ProbeError("%s is not JSON: %s" % (self.path, error)) from None
        if not isinstance(data, dict) or not isinstance(data.get("boxes"), dict):
            raise ProbeError("%s holds no boxes" % self.path)
        return data

    def box(self, box_id):
        return self.load()["boxes"].get(box_id)

    def boxes(self):
        return sorted(self.load()["boxes"])

    def put(self, box_id, entry):
        data = self.load()
        if entry is None:
            data["boxes"].pop(box_id, None)
        else:
            data["boxes"][box_id] = entry
        if data["boxes"]:
            _write_private(self.path, data)
        elif os.path.exists(self.path):
            os.unlink(self.path)


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=True)
        handle.write("\n")


def _read_json(path, default):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, ValueError):
        return default


# -- verdicts -----------------------------------------------------------------------------------------


class Verdicts:
    """Each rule's observations: confirmed, contradicted or not checked, each with its detail (redacted
    when written) and where it came from."""

    def __init__(self, redactor, source="run", log=None):
        self.redactor = redactor
        self.source = source
        self.log = log
        self.items = {}

    def add(self, rule, verdict, detail):
        detail = self.redactor.text(str(detail))
        self.items.setdefault(rule, []).append({"verdict": verdict, "detail": detail, "source": self.source})
        if verdict == "contradicted" and self.log:
            self.log("  %s contradicted: %s" % (rule, detail))

    def confirm(self, rule, detail):
        self.add(rule, "confirmed", detail)

    def contra(self, rule, detail):
        self.add(rule, "contradicted", detail)

    def skip(self, rule, detail):
        self.add(rule, "not checked", detail)

    def check(self, rule, ok, detail, real=None):
        if ok:
            self.confirm(rule, detail)
        else:
            self.contra(rule, "%s; the box: %s" % (detail, real) if real is not None else detail)
        return ok


def combine(entries):
    """One verdict from a rule's observations: contradicted if any, else confirmed if any, else not
    checked."""
    verdicts = {e["verdict"] for e in entries}
    for verdict in ("contradicted", "confirmed"):
        if verdict in verdicts:
            return verdict
    return "not checked"


# -- restoring ----------------------------------------------------------------------------------------


def plan_restore(snapshot, now, inputs):
    """The PUT /execution bodies that bring back the mode, the input and every lastSyncMode of
    `snapshot` from `now`, under SB5 and SB39 (a sync entered sets the box's and the input's
    lastSyncMode; changing the input in passthrough or powersave sets none)."""
    e0, e1 = snapshot.get("execution") or {}, now.get("execution") or {}
    s0, m0, l0 = e0.get("hdmiSource"), e0.get("mode"), e0.get("lastSyncMode")
    want = {k: dig(snapshot, "hdmi.%s.lastSyncMode" % k) for k in inputs}
    have = {k: dig(now, "hdmi.%s.lastSyncMode" % k) for k in inputs}
    needed = [(k, want[k]) for k in inputs if want[k] in SYNC_MODES and have[k] != want[k]]
    order = []
    if m0 in SYNC_MODES:
        order = [(k, m) for k, m in needed if k != s0] + [(s0, m0)]
    else:
        order = list(needed)
        if l0 in SYNC_MODES and (order or e1.get("lastSyncMode") != l0) and (not order or order[-1][1] != l0):
            last = next((item for item in order if item[1] == l0), None)
            if last is None and want.get(s0) == l0:
                last = (s0, l0)
            if last is None:
                last = next(((k, l0) for k in inputs if want[k] == l0), None)
            if last is not None:
                order = [item for item in order if item != last] + [last]
    bodies = []
    cur_input, cur_mode = e1.get("hdmiSource"), e1.get("mode")
    for k, m in order:
        if k == cur_input and m == cur_mode:
            continue
        body = {"mode": m}
        if k != cur_input:
            body = {"hdmiSource": k, "mode": m}
        bodies.append(body)
        cur_input, cur_mode = k, m
    if m0 not in SYNC_MODES:
        if cur_mode in SYNC_MODES:
            bodies.append({"mode": "passthrough"})
            cur_mode = "passthrough"
        if s0 and cur_input != s0:
            bodies.append({"hdmiSource": s0})
        if m0 in ("passthrough", "powersave") and cur_mode != m0:
            bodies.append({"mode": m0})
    return bodies


def restore_paths(snapshot):
    paths = [
        "execution.mode", "execution.syncActive", "execution.hdmiActive", "execution.hdmiSource",
        "execution.hueTarget", "execution.brightness", "execution.lastSyncMode", "execution.video",
        "execution.game", "execution.music", "behavior", "device.name", "device.ledMode", "hue.groupId",
    ]  # fmt: skip
    for port in inputs_of(snapshot) + ["output"]:
        paths += ["hdmi.%s.name" % port, "hdmi.%s.type" % port]
        if port != "output":
            paths.append("hdmi.%s.lastSyncMode" % port)
    return paths


def restore_diff(snapshot, now):
    """[(path, before, now)] for every restored path that differs."""
    missing = object()
    out = []
    for path in restore_paths(snapshot):
        a, b = dig(snapshot, path, missing), dig(now, path, missing)
        if a is missing:
            continue
        if not similar(a, b):
            out.append((path, None if a is missing else a, None if b is missing else b))
    return out


# -- the run ------------------------------------------------------------------------------------------

CHECKS = []


def check(title, *rules):
    """A check of the run: its title and the rules it settles (for --only)."""

    def deco(fn):
        CHECKS.append((fn.__name__, title, rules, fn))
        return fn

    return deco


OWN = object()


class Run:
    """One session with the box: identity, snapshot, checks, restore. `run` and `hands` share it."""

    def __init__(
        self,
        client,
        store,
        *,
        out_dir=DEFAULT_OUT,
        log=print,
        settle_s=SETTLE_S,
        steady_s=STEADY_S,
        poll_s=POLL_S,
        budget_s=BUDGET_S,
        hands_wait_s=HANDS_WAIT_S,
        restart_silence_s=RESTART_SILENCE_S,
        on_prompt=None,
        address=None,
    ):
        self.client = client
        self.store = store
        self.out_dir = out_dir
        self.say = log or (lambda *_: None)
        self.settle_s, self.steady_s, self.poll_s = settle_s, steady_s, poll_s
        self.budget_s = budget_s
        self.hands_wait_s = hands_wait_s
        self.restart_silence_s = restart_silence_s
        self.on_prompt = on_prompt
        self.address = address
        self.redactor = Redactor()
        self.v = Verdicts(self.redactor, log=self._log)
        self.started = client.clock()
        self.state = None
        self.snapshot = None
        self.box_id = None
        self.model = None
        self.reg = None
        self.second = None
        self.own_ids = set()
        self.known_ids = set()
        self.samples = {}
        self.errors = {}
        self.inv = {rule: [0, 0, None] for rule in ("SB3", "SB4", "SB8", "SB10", "SB11", "SB90", "SB113")}
        self.lastused0, self.lastused0_at = None, client.clock()
        self.unkeyed_device = {}
        client.observers.append(self._observe)

    # -- output ------------------------------------------------------------------------------------

    def _log(self, text):
        """A progress line, redacted like everything the probe writes."""
        self.say("[%6.1fs] %s" % (self.client.clock() - self.started, self.redactor.text(str(text))))

    def show(self, answer):
        """An answer for a report line, redacted and cut."""
        if answer is None:
            return "nothing"
        if answer.status is None:
            return "no answer (%s)" % answer.error
        body = (
            json.dumps(answer.body, sort_keys=True, separators=(",", ":")) if answer.body is not None else answer.text
        )
        body = self.redactor.text(body if len(body) <= 240 else body[:240] + "...")
        return "HTTP %s %s" % (answer.status, body)

    def sample(self, name, state):
        if name not in self.samples and isinstance(state, dict):
            self.samples[name] = copy.deepcopy(state)

    # -- identity ----------------------------------------------------------------------------------

    def identify(self, require_registration=True):
        """TLS pinned, the leaf's name against the unkeyed GET /device's uniqueId, and against probe.json's
        box; then the registration. Nothing keyed is sent before this passes."""
        peer = self.client.handshake()
        answer = self.client.request("GET", "/device")
        if answer.status != 200 or not isinstance(answer.body, dict):
            raise ProbeError("no box answers GET /api/v1/device at that address: %s" % self.show(answer))
        box_id = str(answer.body.get("uniqueId") or "").upper()
        if not re.fullmatch(r"[0-9A-F]{12}", box_id):
            raise ProbeError("the device at that address names no 12-digit box id")
        if str(peer.get("cn") or "").upper() != box_id:
            raise ProbeError("the certificate names another box than the one answering GET /device")
        self.client.expected_id = box_id
        self.box_id = box_id
        self.model = answer.body.get("deviceType")
        self.unkeyed_device = answer.body
        self.redactor.learn(answer.body, address=self.address or self.client.host, box_id=box_id)
        entry = self.store.box(box_id) if self.store else None
        if entry is None and self.store and self.store.boxes() and require_registration:
            raise ProbeError("probe.json holds another box than the one at that address: run register here first")
        if require_registration:
            if not entry or not entry.get("token"):
                raise ProbeError("the probe is not registered with this box: run `register` first")
            self.reg = {"id": str(entry.get("registration")), "token": entry["token"]}
            self.redactor.secret(entry["token"])
            self.own_ids.add(self.reg["id"])
            second = entry.get("second")
            if isinstance(second, dict) and second.get("token"):
                self.second = {"id": str(second.get("registration")), "token": second["token"]}
                self.redactor.secret(second["token"])
                self.own_ids.add(self.second["id"])
        self._log(
            "the box answers as %s (firmware %s, API level %s); its certificate chains to the pinned root and"
            " names it" % (self.model, answer.body.get("firmwareVersion"), answer.body.get("apiLevel"))
        )
        return box_id

    # -- requests ----------------------------------------------------------------------------------

    def _guard(self, method, path, body):
        """Refuses, before the network, every request the probe must never send (module's text)."""
        p = path.split("?", 1)[0]
        body = body if isinstance(body, dict) else {}
        if method != "GET" and (p.startswith("/ir") or p.startswith("/presets")):
            raise ProbeError("guard: %s %s is never sent" % (method, p))
        if method == "PUT" and p == "/hue" and set(body) - {"groupId"}:
            raise ProbeError("guard: a bridge change is never sent")
        if method in ("PUT", "POST") and p == "/device" and set(body) & {"action", "update", "bluetooth"}:
            raise ProbeError("guard: a device action, update or bluetooth change is never sent")
        if method == "DELETE":
            match = re.fullmatch(r"/registrations/([^/]+)", p)
            if not match or (match.group(1) in self.known_ids and match.group(1) not in self.own_ids):
                raise ProbeError("guard: DELETE %s is never sent" % p)
        if method == "PUT" and p == "/behavior" and self.snapshot is not None:
            have = self.snapshot.get("behavior") or {}
            for key, value in body.items():
                if isinstance(have.get(key), dict) and isinstance(value, dict):
                    if set(value) - set(have[key]):
                        raise ProbeError("guard: a behavior key the box lacks is never sent")
                elif key not in have and not (key in SB62_CANDIDATES and value == 0):
                    raise ProbeError("guard: a behavior key the box lacks is never sent")

    def req(self, method, path, body=None, token=OWN, raw=None):
        if token is OWN:
            token = self.reg["token"]
        self._guard(method, path, body)
        return self.client.request(method, path, body=body, token=token, raw=raw)

    def put(self, body, path="/execution", token=OWN):
        """A PUT whose answer should be 200: code 16 (the box busy with its bridge a moment) is retried
        after 1, 2 and 4 s; the last answer either way. Refusal checks go through refuse(), never here."""
        answer = self.req("PUT", path, body, token=token)
        for wait in BACKOFF_S:
            if answer.code != 16:
                break
            self.client.sleep(wait)
            answer = self.req("PUT", path, body, token=token)
        return answer

    def _observe(self, method, path, body, answer):
        """SB8, SB10, SB11 on every answer; the error fixtures."""
        if answer.status is None:
            return
        tokens = [r["token"] for r in (self.reg, self.second) if r]
        self._inv("SB8", not any(t and t in answer.text for t in tokens), "%s answered a token" % method)
        if answer.status != 200:
            ok = (
                isinstance(answer.body, dict)
                and isinstance(answer.code, int)
                and isinstance(answer.body.get("message"), str)
            )
            ok = ok and CODE_STATUS.get(answer.code, answer.status) == answer.status
            self._inv("SB10", ok, "%s → %s" % (describe(method, path), self.show(answer)))
            if isinstance(answer.body, dict) and "code" in answer.body:
                key = "code %s" % answer.body.get("code")
                if key not in self.errors:
                    self.errors[key] = {
                        "request": "%s /api/v1%s" % (method, path),
                        "status": answer.status,
                        "body": self.redactor.json(answer.body),
                    }
        else:
            self._inv("SB10", answer.body is not None, "%s → %s" % (describe(method, path), self.show(answer)))
            if method in ("PUT", "DELETE"):
                self._inv("SB11", answer.body == {}, "%s → %s" % (describe(method, path, body), self.show(answer)))

    def _inv(self, rule, ok, sample):
        counts = self.inv[rule]
        counts[0 if ok else 1] += 1
        if not ok and counts[2] is None:
            counts[2] = sample

    def read(self):
        """GET /api/v1 with the token: the state, or None. SB3, SB4, SB90, SB113 on every read."""
        answer = self.req("GET", "")
        if answer.status != 200 or not isinstance(answer.body, dict):
            return None
        st = answer.body
        self.state = st
        e = st.get("execution") or {}
        m = e.get("mode")
        if "syncActive" in e:
            self._inv(
                "SB3", (e["syncActive"] is True) == (m in SYNC_MODES), "mode %s, syncActive %s" % (m, e["syncActive"])
            )
        if "hdmiActive" in e:
            self._inv(
                "SB4", (e["hdmiActive"] is True) == (m != "powersave"), "mode %s, hdmiActive %s" % (m, e["hdmiActive"])
            )
        cs = dig(st, "hue.connectionState")
        if cs is not None:
            self._inv("SB90", cs in CONNECTION_STATES, "connectionState %s" % cs)
        dev = st.get("device") or {}
        self._inv(
            "SB113",
            str(dev.get("uniqueId", "")).upper() == self.box_id and dev.get("deviceType") == self.model,
            "uniqueId or deviceType changed",
        )
        for reg_id in st.get("registrations") or {}:
            self.known_ids.add(str(reg_id))
        return st

    def wait_for(self, pred, timeout=None):
        """Read until pred(state) holds or `timeout` passes: (held, last state)."""
        deadline = self.client.clock() + (self.settle_s if timeout is None else timeout)
        st = None
        while True:
            st = self.read()
            if st is not None and pred(st):
                return True, st
            if self.client.clock() >= deadline:
                return False, st
            self.client.sleep(self.poll_s)

    def steady(self, pred, hold=None):
        """pred holds now and still after `hold` (STEADY_S): (held, last state)."""
        st = self.read()
        if st is None or not pred(st):
            return False, st
        hold = self.steady_s if hold is None else hold
        if hold > 0:
            self.client.sleep(hold)
            st = self.read()
            return st is not None and pred(st), st
        return True, st

    def prep(self, body, path="/execution", until=None, timeout=None, what=None):
        """A PUT that prepares a check: 200, retried on 16 or 503; then `until` (a predicate, or for an
        execution body the mode or input it names). Precondition when it does not happen."""
        answer = self.put(body, path)
        if answer.status != 200:
            raise Precondition("%s was refused: %s" % (what or describe("PUT", path, body), self.show(answer)))
        if until is None and path == "/execution" and isinstance(body, dict):
            if "mode" in body:
                until = lambda s, m=body["mode"]: mode_of(s) == m  # noqa: E731
            elif "hdmiSource" in body:
                until = lambda s, k=body["hdmiSource"]: dig(s, "execution.hdmiSource") == k  # noqa: E731
        if until is not None:
            held, st = self.wait_for(until, timeout)
            if not held:
                raise Precondition(
                    "after %s the box read mode %s on %s"
                    % (what or describe("PUT", path, body), mode_of(st), dig(st, "execution.hdmiSource"))
                )
            return st
        return self.read()

    def refused(self, rule, answer, status, code, what):
        self.v.check(
            rule,
            answer.status == status and answer.code == code,
            "%s → HTTP %d code %d" % (what, status, code),
            None if answer.status == status and answer.code == code else self.show(answer),
        )
        if answer.status == 200 and isinstance(answer.body, dict) and answer.body.get("accessToken"):
            self._drop_stray(answer.body)
        return answer

    def refuse(self, rule, body, status, code, path="/execution", token=OWN, method="PUT", raw=None):
        answer = self.req(method, path, body, token=token, raw=raw)
        return self.refused(rule, answer, status, code, describe(method, path, body, raw))

    def _drop_stray(self, body):
        """A registration a refusal check made by accident: deleted at once with its own token."""
        reg_id, token = str(body.get("registrationId")), body.get("accessToken")
        self.redactor.secret(token)
        self.own_ids.add(reg_id)
        answer = self.client.request("DELETE", "/registrations/%s" % reg_id, token=token)
        self._log("a registration was made by accident and deleted again: %s" % self.show(answer))

    # -- box facts ---------------------------------------------------------------------------------

    @property
    def inputs(self):
        return inputs_of(self.snapshot)

    @property
    def level(self):
        level = dig(self.snapshot, "device.apiLevel")
        return level if isinstance(level, int) else 0

    @property
    def bridge_mode(self):
        hue = (self.snapshot or {}).get("hue")
        return isinstance(hue, dict) and hue.get("operatingMode") != "standalone"

    @property
    def areas(self):
        return sorted(dig(self.snapshot, "hue.groups") or {})

    @property
    def area0(self):
        return dig(self.snapshot, "execution.hueTarget") or dig(self.snapshot, "hue.groupId")

    @property
    def area2(self):
        return next((a for a in self.areas if a != self.area0), None)

    @property
    def source0(self):
        return dig(self.snapshot, "execution.hdmiSource")

    def other_input(self, than, prefer_status=None):
        others = [k for k in self.inputs if k != than]
        if prefer_status:
            same = [k for k in others if dig(self.state, "hdmi.%s.status" % k) == prefer_status]
            if same:
                return same[0]
        return others[0] if others else None

    def ensure(self, mode, source=None):
        """The box in `mode` (on `source` when given), waiting for a sync to reach the bridge."""
        st = self.read()
        if st is None:
            raise Precondition("the box did not answer GET /api/v1")
        if source and dig(st, "execution.hdmiSource") != source:
            if mode_of(st) in SYNC_MODES:
                st = self.prep({"mode": "passthrough"})
            st = self.prep({"hdmiSource": source})
        if mode_of(st) != mode:
            st = self.prep({"mode": mode})
        if mode in SYNC_MODES and self.bridge_mode:
            self.wait_for(lambda s: dig(s, "hue.connectionState") == "streaming")
        return self.state

    def streaming_to(self, area):
        return lambda s: dig(s, "hue.connectionState") == "streaming" and dig(s, "hue.groups.%s.active" % area) is True

    def stopped(self, area):
        return lambda s: dig(s, "hue.connectionState") == "connected" and dig(s, "hue.groups.%s.active" % area) is False

    # -- restoring ---------------------------------------------------------------------------------

    def restore_settings(self):
        """The snapshot's behavior, port names and types, device name and LED, brightness, the three modes'
        settings and the area: each PUT only for what differs."""
        st = self.read()
        snap = self.snapshot
        if st is None or snap is None:
            return
        b0, b1 = snap.get("behavior") or {}, st.get("behavior") or {}
        body = {}
        for key, value in b0.items():
            if isinstance(value, dict):
                inner = {k: v for k, v in value.items() if not isinstance(v, dict) and dig(b1, "%s.%s" % (key, k)) != v}
                if inner:
                    body[key] = inner
            elif b1.get(key) != value:
                body[key] = value
        if body:
            self._restore_put(body, "/behavior")
        for port in self.inputs + ["output"]:
            p0, p1 = dig(snap, "hdmi.%s" % port) or {}, dig(st, "hdmi.%s" % port) or {}
            body = {k: p0[k] for k in ("name", "type") if k in p0 and p1.get(k) != p0[k]}
            if body:
                self._restore_put(body, "/hdmi/%s" % port)
        d0, d1 = snap.get("device") or {}, st.get("device") or {}
        body = {k: d0[k] for k in ("name", "ledMode") if k in d0 and d1.get(k) != d0[k]}
        if body:
            self._restore_put(body, "/device")
        e0, e1 = snap.get("execution") or {}, st.get("execution") or {}
        body = {}
        if "brightness" in e0 and e1.get("brightness") != e0["brightness"]:
            body["brightness"] = e0["brightness"]
        for m, keys in (
            ("video", ("intensity", "backgroundLighting")),
            ("game", ("intensity", "backgroundLighting")),
            ("music", ("intensity", "palette")),
        ):
            diff = {k: e0[m][k] for k in keys if k in (e0.get(m) or {}) and (e1.get(m) or {}).get(k) != e0[m][k]}
            if diff:
                body[m] = diff
        if self.bridge_mode and e0.get("hueTarget") and e1.get("hueTarget") != e0["hueTarget"]:
            body["hueTarget"] = e0["hueTarget"]
        if body:
            self._restore_put(body, "/execution")

    def _restore_put(self, body, path):
        try:
            self.prep(body, path, what="restoring %s" % path)
        except Precondition as error:
            self._log("restore: %s" % error)

    def restore_all(self):
        """Everything back (restore_settings, then the modes and inputs of plan_restore), then read again:
        [(path, before, now)] for whatever still differs."""
        self.restore_settings()
        st = self.read()
        if st is not None:
            for body in plan_restore(self.snapshot, st, self.inputs):
                try:
                    self.prep(body, what="restoring %s" % json.dumps(body, sort_keys=True))
                    if body.get("mode") in SYNC_MODES and self.bridge_mode:
                        self.wait_for(lambda s: dig(s, "hue.connectionState") == "streaming")
                except Precondition as error:
                    self._log("restore: %s" % error)
            self.restore_settings()
        final = self.read()
        return restore_diff(self.snapshot, final) if final is not None else [("everything", "read", "no answer")]

    # -- the checks --------------------------------------------------------------------------------

    @check("the state", "SB1", "SB12", "SB14", "SB62", "SB64", "SB84", "SB85", "SB88")
    def c_state(self):
        st = self.snapshot
        need = ["device", "execution", "hdmi", "behavior", "hue", "registrations", "presets"]
        missing = [k for k in need if k not in st]
        ir_ok = ("ir" not in st) if self.model == "HSB3" else ("ir" in st)
        self.v.check(
            "SB1",
            not missing and ir_ok,
            "GET /api/v1 holds device, execution, hdmi, behavior, hue, registrations, presets%s"
            % (" and no ir (HSB3)" if self.model == "HSB3" else " and ir"),
            "missing %s%s" % (", ".join(missing) or "nothing", "" if ir_ok else "; ir is the other way"),
        )
        unkeyed = self.unkeyed_device
        leaked = [k for k in ("wifi", "update", "ledMode", "action", "pushlink") if k in unkeyed]
        lacking = [k for k in ("name", "deviceType", "uniqueId", "apiLevel", "firmwareVersion") if k not in unkeyed]
        self.v.check(
            "SB12",
            not leaked and not lacking,
            "GET /device without a token answers the identifying fields only (keys: %s)" % ", ".join(sorted(unkeyed)),
            "also %s; lacks %s" % (", ".join(leaked) or "nothing", ", ".join(lacking) or "nothing"),
        )
        answer = self.req("GET", "/device")
        body = answer.body if isinstance(answer.body, dict) else {}
        more = sorted(set(body) - set(unkeyed))
        self.v.check(
            "SB14",
            answer.status == 200 and set(unkeyed) <= set(body) and bool(more),
            "GET /device with the token answers the whole device (also %s)" % ", ".join(more),
            self.show(answer),
        )
        # SB62 and SB64: the behavior keys of this model and level.
        behavior = st.get("behavior") or {}
        top = {"arcBypassMode", "cecPowersave", "inactivePowersave"}
        per_input = {"cecInputSwitch", "linkAutoSync"}
        if self.model in ("HSB1", "HSB2"):
            top |= {"usbPowersave", "hpdInputSwitch"}
        if self.model == "HSB1":
            top.add("forceDoviNative")
            per_input.add("hdrMode")
        if self.level >= 14:
            top.add("soloMode")
        if self.level >= 10:
            per_input.add("hpdInputPortSwitch")
        foreign = {"forceDoviNative", "hdrMode"} if self.model != "HSB1" else set()
        if self.model == "HSB3":
            foreign |= {"usbPowersave", "hpdInputSwitch"}
        have_top = {k for k, v in behavior.items() if not isinstance(v, dict)}
        lacks = sorted(top - have_top)
        for k in self.inputs:
            lacks += ["%s.%s" % (k, f) for f in sorted(per_input - set(behavior.get(k) or {}))]
        wrong = sorted(have_top & foreign)
        for k in self.inputs:
            wrong += ["%s.%s" % (k, f) for f in sorted(set(behavior.get(k) or {}) & foreign)]
        extra = sorted(have_top - top - foreign)
        self.v.check(
            "SB62",
            not lacks and not wrong,
            "the behavior keys of %s at level %d%s"
            % (self.model, self.level, "; also: %s" % ", ".join(extra) if extra else ""),
            "lacks %s; has another model's %s" % (", ".join(lacks) or "nothing", ", ".join(wrong) or "nothing"),
        )
        want64 = ["arcBypassMode"] + (["soloMode"] if self.level >= 14 else [])
        self.v.check(
            "SB64",
            all(k in behavior for k in want64),
            "%s stored and shown" % " and ".join(want64),
            "lacks %s" % ", ".join(k for k in want64 if k not in behavior),
        )
        # SB84: the probe's registration as the box lists it.
        regs = st.get("registrations") or {}
        for reg in [r for r in (self.reg, self.second) if r]:
            entry = regs.get(reg["id"])
            if not isinstance(entry, dict):
                self.v.contra("SB84", "registration %s is not listed by GET /api/v1" % reg["id"])
                continue
            want = {"appName": APP_NAME, "instanceName": INSTANCE_NAME, "role": "user"}
            if self.level >= 10:
                want["verified"] = False
            bad = {k: entry.get(k) for k, v in want.items() if entry.get(k) != v}
            bad.update({k: "absent" for k in ("created", "lastUsed") if k not in entry})
            self.v.check(
                "SB84",
                not bad,
                "a new registration lists role user%s, created and lastUsed"
                % (", verified false" if self.level >= 10 else ""),
                json.dumps(bad, sort_keys=True),
            )
        self.lastused0 = dig(regs, "%s.lastUsed" % self.reg["id"])
        self.lastused0_at = self.client.clock()
        if self.second:
            first, second = regs.get(self.reg["id"]), regs.get(self.second["id"])
            same = (
                isinstance(first, dict)
                and isinstance(second, dict)
                and self.reg["id"] != self.second["id"]
                and first.get("appName") == second.get("appName")
                and first.get("instanceName") == second.get("instanceName")
            )
            answer = self.req("GET", "/registrations", token=self.second["token"])
            mine = self.req("GET", "/registrations")
            self.v.check(
                "SB85",
                same and answer.status == 200 and mine.status == 200,
                "the same names registered twice are two registrations, each token working on its own",
                "listed %s and %s; the second token: %s" % (bool(first), bool(second), self.show(answer)),
            )
        else:
            self.v.skip("SB85", HANDS["SB85"])

    @check("paths", "SB2")
    def c_paths(self):
        st = self.read()
        k = self.inputs[0]
        objects = [("/execution", "execution"), ("/hdmi/%s" % k, "hdmi.%s" % k)]
        if isinstance(dig(st, "behavior.%s" % k), dict):
            objects.append(("/behavior/%s" % k, "behavior.%s" % k))
        if self.area0 and dig(st, "hue.groups.%s" % self.area0) is not None:
            objects.append(("/hue/groups/%s" % self.area0, "hue.groups.%s" % self.area0))
        objects.append(("/registrations/%s" % self.reg["id"], "registrations.%s" % self.reg["id"]))
        for path, dotted in objects:
            answer = self.req("GET", path)
            self.v.check(
                "SB2",
                answer.status == 200 and similar(answer.body, dig(st, dotted)),
                "GET %s answers %s as GET /api/v1 shows it" % (path, dotted),
                self.show(answer),
            )
        for path in ("/nothing", "/execution/mode", "/hdmi/input%d" % (len(self.inputs) + 1)):
            self.refuse("SB2", None, 404, 10, path=path, method="GET")

    @check("tokens", "SB12", "SB13")
    def c_auth(self):
        b = dig(self.read(), "execution.brightness", 100)
        for method, path, body in (
            ("GET", "", None),
            ("GET", "/execution", None),
            ("PUT", "/execution", {"brightness": b}),
        ):
            self.refuse("SB12", body, 401, 2, path=path, token=None, method=method)
        stray = {"appName": APP_NAME, "instanceName": INSTANCE_NAME + "-stray"}
        for method, path, body in (("GET", "/device", None), ("GET", "", None), ("POST", "/registrations", stray)):
            self.refuse("SB13", body, 401, 2, path=path, token=WRONG_TOKEN, method=method)

    @check("methods", "SB15")
    def c_methods(self):
        st = self.read()
        b, name = dig(st, "execution.brightness", 100), dig(st, "device.name", "Sync Box")
        self.refuse("SB15", {"brightness": b}, 404, 10, method="POST")
        self.refuse("SB15", {"execution": {"brightness": b}}, 404, 10, path="")
        self.refuse("SB15", {"name": name}, 404, 10, path="/device", method="POST")

    @check("bodies", "SB16", "SB17", "SB18", "SB19", "SB20", "SB21", "SB56")
    def c_bodies(self):
        st = self.read()
        b = dig(st, "execution.brightness", 100)
        nb = b + 20 if b <= 180 else b - 20
        self.refuse("SB16", None, 400, 12, raw='{"brightness": ')
        self.refuse("SB17", {}, 400, 13)
        self.refuse("SB17", {}, 400, 13, path="/behavior")
        self.refuse("SB18", {"colour": 1}, 400, 13)
        self.refuse("SB18", {"lastSyncMode": dig(st, "execution.lastSyncMode", "video")}, 400, 13)
        self.refuse("SB18", {"uniqueId": dig(st, "device.uniqueId")}, 400, 13, path="/device")
        self.refuse("SB19", {"brightness": 300}, 400, 15)
        self.refuse("SB19", {"syncActive": "yes"}, 400, 15)
        self.refuse("SB19", {"brightness": "100"}, 400, 15)
        for body in ({"brightness": nb, "intensity": "bogus"}, {"brightness": nb, "hdmiSource": "input9"}):
            self.refuse("SB20", body, 400, 15)
            after = dig(self.read(), "execution.brightness")
            self.v.check(
                "SB20",
                after == b,
                "after the refused %s brightness still reads %s" % (json.dumps(body), b),
                "brightness %s" % after,
            )
        other = self.other_input(dig(st, "execution.hdmiSource"))
        if other:
            # SB56: a valid field applied early (the input, step 3) with a bad one applied late (step 9).
            self.refuse("SB56", {"hdmiSource": other, "brightness": 300}, 400, 15)
            now = dig(self.read(), "execution.hdmiSource")
            self.v.check(
                "SB56",
                now == dig(st, "execution.hdmiSource"),
                "the whole PUT is checked before any of it applies: the input did not change",
                "the input changed to %s" % now,
            )
        self.refuse("SB21", {"colour": 1, "brightness": 300}, 400, 13)
        self.refuse("SB21", None, 400, 12, raw='{"colour": 1, "brightness": 300')
        self.refuse(
            "SB21",
            {"appName": "", "instanceName": INSTANCE_NAME},
            400,
            15,
            path="/registrations",
            token=None,
            method="POST",
        )

    @check("values", "SB40", "SB42", "SB43", "SB47", "SB48", "SB49", "SB51")
    def c_values(self):
        st = self.read()
        before = mode_of(st)
        self.refuse("SB40", {"hdmiSource": "input%d" % (len(self.inputs) + 1)}, 400, 15)
        self.refuse("SB40", {"hdmiSource": "hdmi1"}, 400, 15)
        for value in (201, -1):
            self.refuse("SB42", {"brightness": value}, 400, 15)
        for value in (201, -201):
            self.refuse("SB43", {"incrementBrightness": value}, 400, 15)
        self.refuse("SB47", {"music": {"colour": 1}}, 400, 13)
        self.refuse("SB47", {"music": {"palette": "x"}}, 400, 15)
        self.refuse("SB47", {"video": {"palette": "neutral"}}, 400, 13)
        if self.bridge_mode:
            self.refuse("SB48", {"hueTarget": "00000000-0000-4000-8000-00000000d0d0"}, 400, 15)
        presets = dig(st, "presets") or {}
        numbers = [int(k) for k in presets if str(k).isdigit()]
        self.refuse("SB49", {"preset": str(max(numbers + [0]) + 900)}, 400, 15)
        for value in ("ambient", "off"):
            answer = self.refuse("SB51", {"mode": value}, 400, 15)
            if answer.status == 200 and before:
                self._restore_put({"mode": before}, "/execution")

    @check("settings refused", "SB60", "SB61", "SB62", "SB80", "SB81", "SB86", "SB94", "SB100", "SB110", "SB111")
    def c_refusals(self):
        st = self.read()
        before = mode_of(st)
        behavior = st.get("behavior") or {}
        k0 = self.inputs[0]
        self.refuse("SB60", {"cecPowersave": True}, 400, 15, path="/behavior")
        if isinstance(behavior.get(k0), dict) and "cecInputSwitch" in behavior[k0]:
            self.refuse("SB60", {"cecInputSwitch": behavior[k0]["cecInputSwitch"]}, 404, 10, path="/behavior/%s" % k0)
        for value in (10001, -1):
            self.refuse("SB61", {"inactivePowersave": value}, 400, 15, path="/behavior")
        lacking = next((k for k in SB62_CANDIDATES if k not in behavior), None)
        if lacking:
            self.refuse("SB62", {lacking: 0}, 400, 13, path="/behavior")
        self.refuse("SB80", {"appName": APP_NAME}, 400, 15, path="/registrations", token=None, method="POST")
        self.refuse(
            "SB80",
            {"appName": "", "instanceName": INSTANCE_NAME},
            400,
            15,
            path="/registrations",
            token=None,
            method="POST",
        )
        self.refuse(
            "SB81",
            {"appName": APP_NAME, "instanceName": INSTANCE_NAME + "-stray"},
            400,
            16,
            path="/registrations",
            token=None,
            method="POST",
        )
        numbers = [int(k) for k in (st.get("registrations") or {}) if str(k).isdigit()]
        self.refuse("SB86", None, 404, 10, path="/registrations/%d" % (max(numbers + [0]) + 1000), method="DELETE")
        if self.bridge_mode and self.area0:
            answer = self.refuse("SB94", {"active": True}, 400, 15, path="/hue/groups/%s" % self.area0)
            if answer.status == 200 and before:
                self._restore_put({"mode": before}, "/execution")
            self.refuse("SB94", {"active": False}, 404, 10, path="/hue/groups/00000000-0000-4000-8000-00000000d0d0")
        last = self.inputs[-1]
        port = "/hdmi/%s" % last
        self.refuse("SB100", {"status": "linked"}, 400, 13, path=port)
        self.refuse("SB100", {"lastSyncMode": "video"}, 400, 13, path=port)
        self.refuse("SB100", {"type": "bogus"}, 400, 15, path=port)
        self.refuse("SB100", {"name": ""}, 400, 15, path=port)
        self.refuse("SB100", {"name": "HDMI"}, 404, 10, path="/hdmi/input%d" % (len(self.inputs) + 1))
        self.refuse("SB100", {last: {"name": dig(st, "hdmi.%s.name" % last, "HDMI")}}, 404, 10, path="/hdmi")
        self.refuse("SB110", {"name": ""}, 400, 15, path="/device")
        self.refuse("SB110", {"ledMode": 3}, 400, 15, path="/device")
        self.refuse("SB111", {"apiLevel": dig(st, "device.apiLevel", 0)}, 400, 13, path="/device")

    @check("settings", "SB42", "SB43", "SB47", "SB60", "SB61", "SB100", "SB110")
    def c_settings(self):
        st = self.read()
        before = copy.deepcopy(st.get("execution") or {})
        for value in (0, 200):
            self.prep({"brightness": value})
            got = dig(self.read(), "execution.brightness")
            self.v.check("SB42", got == value, "brightness %d is taken and reads back" % value, "reads %s" % got)
        for start, step, want in ((150, 100, 200), (50, -100, 0), (0, 30, 30)):
            self.prep({"brightness": start})
            self.prep({"incrementBrightness": step})
            got = dig(self.read(), "execution.brightness")
            self.v.check(
                "SB43",
                got == want,
                "brightness %d, incrementBrightness %+d → %d" % (start, step, want),
                "reads %s" % got,
            )
        target = next(
            (m for m in ("game", "music", "video") if m != mode_of(st) and m != before.get("lastSyncMode")), "game"
        )
        x = other_intensity(dig(before, "%s.intensity" % target))
        self.prep({target: {"intensity": x}})
        st2 = self.read()
        self.v.check(
            "SB47",
            dig(st2, "execution.%s.intensity" % target) == x and mode_of(st2) == mode_of(st),
            "{%s: {intensity: %s}} sets that mode's setting and keeps the mode %s" % (target, x, mode_of(st)),
            "%s.intensity %s, mode %s" % (target, dig(st2, "execution.%s.intensity" % target), mode_of(st2)),
        )
        cec = dig(st, "behavior.cecPowersave")
        if cec in (0, 1):
            answer = self.put({"cecPowersave": cec}, "/behavior")
            self.v.check("SB60", answer.status == 200, "a flag sent as the number %d is taken" % cec, self.show(answer))
        for value in (10000, 0):
            self.prep({"inactivePowersave": value}, "/behavior")
            got = dig(self.read(), "behavior.inactivePowersave")
            self.v.check("SB61", got == value, "inactivePowersave %d is taken" % value, "reads %s" % got)
        last = self.inputs[-1]
        name = "HDMI %s probe" % last[5:]
        self.prep({"name": name}, "/hdmi/%s" % last)
        st3 = self.read()
        self.v.check(
            "SB100",
            dig(st3, "hdmi.%s.name" % last) == name,
            "PUT /hdmi/%s {name} renames the port" % last,
            "reads %r" % dig(st3, "hdmi.%s.name" % last),
        )
        answer = self.put({"type": dig(st3, "hdmi.%s.type" % last, "generic")}, "/hdmi/%s" % last)
        self.v.check("SB100", answer.status == 200, "PUT /hdmi/%s {type} is taken" % last, self.show(answer))
        for key in ("name", "ledMode"):
            if key in (st.get("device") or {}):
                answer = self.put({key: st["device"][key]}, "/device")
                self.v.check("SB110", answer.status == 200, "PUT /device {%s} is taken" % key, self.show(answer))

    @check("passthrough", "SB6", "SB30", "SB33", "SB34", "SB36")
    def c_passthrough(self):
        st = self.read()
        was = mode_of(st)
        st = self.prep({"mode": "passthrough"})
        self.v.confirm("SB30", "{mode: passthrough} from %s → passthrough" % was)
        self.sample("passthrough", st)
        if was in SYNC_MODES and self.bridge_mode and self.area0:
            held, st = self.wait_for(self.stopped(self.area0))
            self.v.check(
                "SB6",
                held,
                "stopping a sync makes the link connected and the area inactive",
                "connectionState %s, area active %s"
                % (dig(st, "hue.connectionState"), dig(st, "hue.groups.%s.active" % self.area0)),
            )
        for rule, body in (
            ("SB33", {"syncActive": False}),
            ("SB36", {"toggleSyncActive": False}),
            ("SB36", {"toggleHdmiActive": False}),
            ("SB34", {"hdmiActive": True}),
        ):
            answer = self.put(body)
            held, st = self.steady(lambda s: mode_of(s) == "passthrough")
            self.v.check(
                rule,
                answer.status == 200 and held,
                "in passthrough %s → 200 and no change" % json.dumps(body),
                "%s, then mode %s" % (self.show(answer), mode_of(st)),
            )

    @check("behavior writes", "SB63")
    def c_behavior_quiet(self):
        st = self.ensure("passthrough", self.source0)
        behavior = st.get("behavior") or {}
        body = {}
        if "hpdInputSwitch" in behavior:
            body["hpdInputSwitch"] = 1
        for k in self.inputs:
            flags = behavior.get(k) or {}
            inner = {f: 1 for f in ("cecInputSwitch", "linkAutoSync") if f in flags}
            if inner:
                body[k] = inner
        before = (mode_of(st), dig(st, "execution.hdmiSource"))
        self.prep(body, "/behavior")
        held, st = self.steady(lambda s: (mode_of(s), dig(s, "execution.hdmiSource")) == before, hold=2 * self.steady_s)
        self.v.check(
            "SB63",
            held,
            "behavior writes (CEC, hot-plug and auto-sync on) change nothing until an event",
            "mode %s on %s" % (mode_of(st), dig(st, "execution.hdmiSource")),
        )

    @check("settings outside sync", "SB44", "SB45", "SB46")
    def c_settings_mode(self):
        st = self.ensure("passthrough")
        last = dig(st, "execution.lastSyncMode")
        last = last if last in SYNC_MODES else "video"
        e = st["execution"]
        x = other_intensity(dig(e, "%s.intensity" % last))
        others = {m: dig(e, "%s.intensity" % m) for m in SYNC_MODES if m != last}
        self.prep({"intensity": x})
        st = self.read()
        got = {m: dig(st, "execution.%s.intensity" % m) for m in SYNC_MODES}
        self.v.check(
            "SB44",
            got[last] == x and all(got[m] == v for m, v in others.items()) and mode_of(st) == "passthrough",
            "{intensity: %s} in passthrough writes lastSyncMode %s's and nothing else" % (x, last),
            json.dumps(got, sort_keys=True),
        )
        self.prep({"intensity": "intense"})
        for direction, want in (("next", "subtle"), ("previous", "intense")):
            self.prep({"cycleIntensity": direction})
            got = dig(self.read(), "execution.%s.intensity" % last)
            self.v.check("SB45", got == want, "cycleIntensity %s wraps to %s" % (direction, want), "reads %s" % got)
        if last != "music":
            bl = dig(st, "execution.%s.backgroundLighting" % last)
            if isinstance(bl, bool):
                self.prep({"backgroundLighting": not bl})
                got = dig(self.read(), "execution.%s.backgroundLighting" % last)
                self.v.check(
                    "SB46", got is (not bl), "backgroundLighting goes on lastSyncMode %s's" % last, "reads %s" % got
                )
                self.prep({"toggleBackgroundLighting": True})
                got = dig(self.read(), "execution.%s.backgroundLighting" % last)
                self.v.check("SB46", got is bl, "toggleBackgroundLighting flips it back", "reads %s" % got)
        else:
            self.refuse("SB46", {"backgroundLighting": True}, 400, 15)

    def _sample78(self):
        """SB78 on the selected input: linked → specs and true, true; otherwise "", false, false."""

        def consistent(s):
            port = dig(s, "execution.hdmiSource")
            linked = dig(s, "hdmi.%s.status" % port) == "linked"
            specs, video, audio = (
                dig(s, "hdmi.%s" % k) for k in ("contentSpecs", "videoSyncSupported", "audioSyncSupported")
            )
            if linked:
                return isinstance(specs, str) and bool(specs) and video is True and audio is True
            return specs == "" and video is False and audio is False

        st = self.read()
        if dig(st, "hdmi.contentSpecs") is None:
            self.v.skip("SB78", "this box shows no hdmi.contentSpecs")
            return
        held, st = self.wait_for(consistent, timeout=4.0 if self.settle_s else 0)
        port = dig(st, "execution.hdmiSource")
        status = dig(st, "hdmi.%s.status" % port)
        self.v.check(
            "SB78",
            held,
            "%s reads %s: contentSpecs %r, videoSyncSupported %s, audioSyncSupported %s"
            % (
                port,
                status,
                dig(st, "hdmi.contentSpecs"),
                dig(st, "hdmi.videoSyncSupported"),
                dig(st, "hdmi.audioSyncSupported"),
            ),
            "inconsistent for 4 s",
        )

    @check("inputs", "SB41", "SB78")
    def c_inputs(self):
        if len(self.inputs) < 2:
            self.v.skip("SB41", "a one-input box")
            self._sample78()
            return
        self.ensure("passthrough")
        first, last = self.inputs[0], self.inputs[-1]
        self.prep({"hdmiSource": last})
        self._sample78()
        for direction, want in (("next", first), ("previous", last)):
            answer = self.put({"cycleHdmiSource": direction})
            held, st = self.wait_for(lambda s, w=want: dig(s, "execution.hdmiSource") == w, timeout=4.0)
            self.v.check(
                "SB41",
                answer.status == 200 and held,
                "cycleHdmiSource %s wraps to %s" % (direction, want),
                "%s, then %s" % (self.show(answer), dig(st, "execution.hdmiSource")),
            )
            if direction == "next":
                self._sample78()
        for k in self.inputs[1:-1]:
            self.prep({"hdmiSource": k})
            self._sample78()
        self.prep({"hdmiSource": self.source0})

    @check("linked input", "SB72", "SB73")
    def c_linked(self):
        st = self.ensure("passthrough")
        linked = [k for k in self.inputs if dig(st, "hdmi.%s.status" % k) == "linked"]
        if not linked or dig(st, "hdmi.output.status") != "linked":
            for rule in ("SB72", "SB73"):
                self.v.skip(rule, "no input and output read linked (no source on): " + HANDS["SB73"])
            return
        k = self.source0 if self.source0 in linked else linked[0]
        self.prep({"hdmiSource": k})
        if isinstance(dig(st, "behavior.%s.linkAutoSync" % k), int):
            self.prep({k: {"linkAutoSync": 1}}, "/behavior")
        self.prep({"hdmiActive": False}, until=lambda s: mode_of(s) == "powersave")
        held, st = self.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) == "plugged", timeout=4.0)
        self.sample("powersave", st)
        self.v.check(
            "SB72", held, "in powersave the linked %s reads plugged" % k, "reads %s" % dig(st, "hdmi.%s.status" % k)
        )
        self.prep({"hdmiActive": True}, until=lambda s: mode_of(s) != "powersave")
        held, st = self.steady(lambda s: mode_of(s) == "passthrough", hold=3 * self.steady_s)
        self.v.check(
            "SB73",
            held,
            "waking onto the linked %s with linkAutoSync 1 by a request starts no sync" % k,
            "mode %s" % mode_of(st),
        )
        held, st = self.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) == "linked", timeout=4.0)
        self.v.check("SB72", held, "awake again, %s reads linked" % k, "reads %s" % dig(st, "hdmi.%s.status" % k))

    @check("sync", "SB3", "SB4", "SB5", "SB6", "SB30", "SB32", "SB37", "SB38")
    def c_sync(self):
        self.ensure("passthrough", self.source0)
        answer = self.put({"mode": "game"})
        if answer.status != 200:
            raise Precondition(
                "the box would not sync: {mode: game} → %s (link %s)"
                % (self.show(answer), dig(self.state, "hue.connectionState"))
            )
        held, st = self.wait_for(lambda s: mode_of(s) == "game")
        if not self.v.check("SB30", held, "{mode: game} from passthrough → game", "mode %s" % mode_of(st)):
            raise Precondition("the box took {mode: game} but did not sync")
        self.sample("syncing", st)
        s0 = self.source0
        self.v.check(
            "SB5",
            dig(st, "execution.lastSyncMode") == "game" and dig(st, "hdmi.%s.lastSyncMode" % s0) == "game",
            "entering game sets execution.lastSyncMode and %s's to game" % s0,
            "%s and %s" % (dig(st, "execution.lastSyncMode"), dig(st, "hdmi.%s.lastSyncMode" % s0)),
        )
        if self.bridge_mode and self.area0:
            held, st = self.wait_for(self.streaming_to(self.area0))
            self.v.check(
                "SB6",
                held,
                "syncing makes the link streaming and the area active",
                "connectionState %s" % dig(st, "hue.connectionState"),
            )
        answer = self.put({"syncActive": True})
        held, st = self.steady(lambda s: mode_of(s) == "game")
        self.v.check(
            "SB32",
            answer.status == 200 and held,
            "{syncActive: true} while syncing changes nothing",
            "mode %s" % mode_of(st),
        )
        self.put({"toggleSyncMode": "game"})
        held, st = self.wait_for(lambda s: mode_of(s) == "passthrough")
        self.v.check("SB37", held, "{toggleSyncMode: game} while syncing game → passthrough", "mode %s" % mode_of(st))
        if held and self.bridge_mode and self.area0:
            held, st = self.wait_for(self.stopped(self.area0))
            self.v.check(
                "SB6",
                held,
                "stopping a sync makes the link connected and the area inactive",
                "connectionState %s" % dig(st, "hue.connectionState"),
            )
        self.put({"toggleSyncMode": "video"})
        held, st = self.wait_for(lambda s: mode_of(s) == "video")
        self.v.check("SB37", held, "{toggleSyncMode: video} from passthrough → video", "mode %s" % mode_of(st))
        seen, current = [], mode_of(st)
        for direction in ("next", "next", "next", "previous"):
            self.put({"cycleSyncMode": direction})
            held, st = self.wait_for(
                lambda s, c=current: mode_of(s) != c and mode_of(s) in SYNC_MODES, timeout=self.settle_s
            )
            want = cycle(SYNC_CYCLE, current, direction)
            seen.append("%s %s→%s" % (direction, current, mode_of(st)))
            self.v.check(
                "SB38",
                mode_of(st) == want,
                "cycleSyncMode %s from %s → %s" % (direction, current, want),
                "; ".join(seen),
            )
            current = mode_of(st)
        st = self.prep({"mode": "passthrough"})
        last = dig(st, "execution.lastSyncMode")
        want = cycle(SYNC_CYCLE, last, "next")
        self.put({"cycleSyncMode": "next"})
        held, st = self.wait_for(lambda s: mode_of(s) in SYNC_MODES)
        self.v.check(
            "SB38",
            mode_of(st) == want,
            "cycleSyncMode next from passthrough counts from lastSyncMode %s → %s" % (last, want),
            "mode %s" % mode_of(st),
        )

    @check("music", "SB46", "SB55")
    def c_music(self):
        self.ensure("music")
        self.refuse("SB46", {"backgroundLighting": True}, 400, 15)
        self.refuse("SB46", {"toggleBackgroundLighting": True}, 400, 15)
        st = self.read()
        x = other_intensity(dig(st, "execution.game.intensity"))
        music = dig(st, "execution.music.intensity")
        self.put({"mode": "game", "intensity": x})
        held, st = self.wait_for(lambda s: mode_of(s) == "game")
        self.v.check(
            "SB55",
            held and dig(st, "execution.game.intensity") == x and dig(st, "execution.music.intensity") == music,
            "{mode: game, intensity: %s} puts the intensity on game" % x,
            "mode %s, game %s, music %s"
            % (mode_of(st), dig(st, "execution.game.intensity"), dig(st, "execution.music.intensity")),
        )

    @check("areas", "SB7", "SB48", "SB95")
    def c_area(self):
        if not self.bridge_mode or not self.area0:
            raise Precondition("the box has no bridge area")
        a0, a2 = self.area0, self.area2
        if self.level < 10:
            self.refuse("SB95", {"groupId": a0}, 400, 13, path="/hue")
        if a2 is None:
            st = self.read()
            if "groupId" in (st.get("hue") or {}):
                self.v.check(
                    "SB7",
                    dig(st, "hue.groupId") == dig(st, "execution.hueTarget"),
                    "hue.groupId names the hueTarget area (one area: no change tried)",
                    dig(st, "hue.groupId"),
                )
            self.v.skip("SB48", "the bridge has one entertainment area")
            if self.level >= 10:
                self.v.skip("SB95", "the bridge has one entertainment area")
            return
        self.ensure("game")
        answer = self.put({"hueTarget": a2})
        st = self.read()
        self.v.check(
            "SB48",
            answer.status == 200 and dig(st, "execution.hueTarget") == a2,
            "{hueTarget: <the other area>} is taken and reads as sent",
            self.show(answer),
        )
        if "groupId" in (st.get("hue") or {}):
            self.v.check("SB7", dig(st, "hue.groupId") == a2, "hue.groupId follows hueTarget", dig(st, "hue.groupId"))
        held, st = self.wait_for(lambda s: self.streaming_to(a2)(s) and dig(s, "hue.groups.%s.active" % a0) is False)
        self.v.check(
            "SB48",
            held,
            "while syncing the stream moves: the old area inactive, the new one active",
            "old %s, new %s" % (dig(st, "hue.groups.%s.active" % a0), dig(st, "hue.groups.%s.active" % a2)),
        )
        if self.level >= 10 and "groupId" in (st.get("hue") or {}):
            answer = self.put({"groupId": a0}, "/hue")
            st = self.read()
            self.v.check(
                "SB95",
                answer.status == 200 and dig(st, "execution.hueTarget") == a0,
                "PUT /hue {groupId} selects the area as hueTarget does (level %d)" % self.level,
                "%s, hueTarget %s" % (self.show(answer), dig(st, "execution.hueTarget")),
            )
            self.v.check(
                "SB7",
                dig(st, "hue.groupId") == dig(st, "execution.hueTarget") == a0,
                "hueTarget follows hue.groupId",
                dig(st, "execution.hueTarget"),
            )
        else:
            self.prep({"hueTarget": a0}, until=lambda s: dig(s, "execution.hueTarget") == a0)
        self.wait_for(self.streaming_to(a0))

    @check("input while syncing", "SB39")
    def c_input_sync(self):
        if len(self.inputs) < 2:
            raise Precondition("a one-input box")
        s0 = self.source0
        st = self.ensure("game", s0)
        s2 = self.other_input(s0, prefer_status=dig(st, "hdmi.%s.status" % s0))
        answer = self.put({"hdmiSource": s2})
        self.wait_for(lambda s: dig(s, "execution.hdmiSource") == s2, timeout=4.0)
        held, st = self.steady(
            lambda s: dig(s, "execution.hdmiSource") == s2 and mode_of(s) == "game", hold=2 * self.steady_s
        )
        self.v.check(
            "SB39",
            answer.status == 200 and held,
            "{hdmiSource: %s} while syncing game keeps syncing game (%s reads %s)"
            % (s2, s2, dig(st, "hdmi.%s.status" % s2)),
            "mode %s on %s" % (mode_of(st), dig(st, "execution.hdmiSource")),
        )
        self.v.check(
            "SB39",
            dig(st, "hdmi.%s.lastSyncMode" % s2) == "game",
            "game becomes %s's lastSyncMode" % s2,
            dig(st, "hdmi.%s.lastSyncMode" % s2),
        )
        self.put({"hdmiSource": s0})
        self.wait_for(lambda s: dig(s, "execution.hdmiSource") == s0, timeout=4.0)

    @check("stopping an area's stream", "SB94")
    def c_stop_area(self):
        if not self.bridge_mode or not self.area0:
            raise Precondition("the box has no bridge area")
        a0 = self.area0
        self.ensure("game", self.source0)
        held, _ = self.wait_for(self.streaming_to(a0))
        if not held:
            raise Precondition("the box did not stream to its area")
        answer = self.put({"active": False}, "/hue/groups/%s" % a0)
        held, st = self.wait_for(lambda s: mode_of(s) == "passthrough" and self.stopped(a0)(s))
        self.v.check(
            "SB94",
            answer.status == 200 and held,
            "PUT /hue/groups/<its area> {active: false} → passthrough, connected, the area inactive",
            "%s, then mode %s, link %s" % (self.show(answer), mode_of(st), dig(st, "hue.connectionState")),
        )
        answer = self.put({"active": False}, "/hue/groups/%s" % a0)
        held, st = self.steady(lambda s: mode_of(s) == "passthrough" and dig(s, "hue.groups.%s.active" % a0) is False)
        self.v.check(
            "SB94",
            answer.status == 200 and held,
            "the same on an inactive area → 200 and nothing",
            "%s, mode %s" % (self.show(answer), mode_of(st)),
        )

    @check("sync on and off", "SB32", "SB33", "SB36")
    def c_resume(self):
        st = self.ensure("passthrough", self.source0)
        want = dig(st, "hdmi.%s.lastSyncMode" % self.source0)
        self.put({"syncActive": True})
        held, st = self.wait_for(lambda s: mode_of(s) in SYNC_MODES)
        self.v.check(
            "SB32",
            mode_of(st) == want,
            "{syncActive: true} in passthrough syncs in %s's lastSyncMode %s" % (self.source0, want),
            "mode %s" % mode_of(st),
        )
        self.put({"syncActive": False})
        held, st = self.wait_for(lambda s: mode_of(s) == "passthrough")
        self.v.check("SB33", held, "{syncActive: false} while syncing → passthrough", "mode %s" % mode_of(st))
        for body, want_mode in (
            ({"toggleSyncActive": True}, "sync"),
            ({"toggleSyncActive": True}, "passthrough"),
            ({"toggleHdmiActive": True}, "powersave"),
            ({"toggleHdmiActive": True}, "passthrough"),
        ):
            self.put(body)
            held, st = self.wait_for(
                lambda s, w=want_mode: (mode_of(s) in SYNC_MODES) if w == "sync" else (mode_of(s) == w)
            )
            self.v.check("SB36", held, "%s → %s" % (json.dumps(body), want_mode), "mode %s" % mode_of(st))

    @check("powersave", "SB31", "SB32", "SB33", "SB34", "SB35", "SB36", "SB38", "SB39", "SB50", "SB55")
    def c_powersave(self):
        s0 = self.source0
        st = self.ensure("passthrough", s0)
        self.prep({"syncActive": True}, until=lambda s: mode_of(s) in SYNC_MODES)
        self.put({"hdmiActive": False})
        held, st = self.wait_for(lambda s: mode_of(s) == "powersave")
        self.v.check("SB35", held, "{hdmiActive: false} while syncing → powersave", "mode %s" % mode_of(st))
        if not held:
            raise Precondition("the box did not go to powersave")
        self.sample("powersave", st)
        powersave = lambda s: mode_of(s) == "powersave"  # noqa: E731
        b = dig(st, "execution.brightness", 100)
        nb = b + 30 if b <= 170 else b - 30
        x = other_intensity(dig(st, "execution.video.intensity"))
        settings = [
            ({"brightness": nb}, "execution.brightness", nb),
            ({"video": {"intensity": x}}, "execution.video.intensity", x),
        ]
        if self.bridge_mode and self.area2:
            settings.append(({"hueTarget": self.area2}, "execution.hueTarget", self.area2))
        for body, path, want in settings:
            answer = self.put(body)
            held, st = self.steady(lambda s, p=path, w=want: powersave(s) and dig(s, p) == w)
            self.v.check(
                "SB50",
                answer.status == 200 and held,
                "in powersave %s applies and does not wake" % json.dumps(body),
                "%s, mode %s, %s %s" % (self.show(answer), mode_of(st), path, dig(st, path)),
            )
        if self.bridge_mode and self.area2:
            self.prep({"hueTarget": self.area0}, until=lambda s: dig(s, "execution.hueTarget") == self.area0)
        s2 = self.other_input(s0)
        if s2:
            answer = self.put({"hdmiSource": s2})
            held, st = self.steady(lambda s: powersave(s) and dig(s, "execution.hdmiSource") == s2)
            self.v.check(
                "SB39",
                answer.status == 200 and held,
                "{hdmiSource: %s} in powersave selects it and does not wake" % s2,
                "mode %s on %s" % (mode_of(st), dig(st, "execution.hdmiSource")),
            )
            self.prep({"hdmiSource": s0})
        for rule, body in (("SB33", {"syncActive": False}), ("SB36", {"toggleSyncActive": False})):
            answer = self.put(body)
            held, st = self.steady(powersave)
            self.v.check(
                rule,
                answer.status == 200 and held,
                "in powersave %s → 200 and no change" % json.dumps(body),
                "mode %s" % mode_of(st),
            )
        self.put({"hdmiActive": True})
        held, st = self.wait_for(lambda s: mode_of(s) == "passthrough")
        self.v.check("SB34", held, "{hdmiActive: true} in powersave → passthrough", "mode %s" % mode_of(st))
        self.prep({"hdmiActive": False}, until=powersave)
        want = dig(self.state, "hdmi.%s.lastSyncMode" % s0)
        self.put({"syncActive": True})
        held, st = self.wait_for(lambda s: mode_of(s) in SYNC_MODES)
        self.v.check(
            "SB32",
            mode_of(st) == want,
            "{syncActive: true} in powersave wakes and syncs in %s" % want,
            "mode %s" % mode_of(st),
        )
        self.prep({"hdmiActive": False}, until=powersave)
        self.put({"mode": "video"})
        held, st = self.wait_for(lambda s: mode_of(s) == "video")
        self.v.check("SB31", held, "{mode: video} in powersave wakes and syncs", "mode %s" % mode_of(st))
        st = self.prep({"hdmiActive": False}, until=powersave)
        last = dig(st, "execution.lastSyncMode")
        want = cycle(SYNC_CYCLE, last, "next")
        self.put({"cycleSyncMode": "next"})
        held, st = self.wait_for(lambda s: mode_of(s) in SYNC_MODES)
        self.v.check(
            "SB38",
            mode_of(st) == want,
            "cycleSyncMode next in powersave wakes and syncs in %s (after %s)" % (want, last),
            "mode %s" % mode_of(st),
        )
        st = self.prep({"hdmiActive": False}, until=powersave)
        if s2:
            want = dig(st, "hdmi.%s.lastSyncMode" % s2)
            self.put({"hdmiActive": True, "hdmiSource": s2, "syncActive": True})
            held, st = self.wait_for(lambda s: mode_of(s) in SYNC_MODES and dig(s, "execution.hdmiSource") == s2)
            self.v.check(
                "SB55",
                held and mode_of(st) == want,
                "{hdmiActive: true, hdmiSource: %s, syncActive: true} in powersave wakes, selects %s and syncs"
                " in its %s" % (s2, s2, want),
                "mode %s on %s" % (mode_of(st), dig(st, "execution.hdmiSource")),
            )
            self.prep({"mode": "passthrough"})
            self.prep({"hdmiSource": s0})

    @check("standalone", "SB97")
    def c_standalone(self):
        if dig(self.snapshot, "hue.operatingMode") != "standalone":
            self.v.skip("SB97", NOT_PROBED["SB97"])
            return
        hue = copy.deepcopy(self.read().get("hue"))
        self.refuse("SB97", {"hueTarget": self.area0 or "groups/1"}, 400, 16)
        self.v.check("SB97", similar(self.read().get("hue"), hue), "hue is untouched", "hue changed")

    @check("registrations", "SB85", "SB86", "SB88")
    def c_registrations(self):
        own = self.reg["id"]
        a = dig(self.read(), "registrations.%s.lastUsed" % own)
        self.client.sleep(max(2.0, self.steady_s * 2) if self.steady_s else 0)
        b = dig(self.read(), "registrations.%s.lastUsed" % own)
        if a is None or b is None:
            self.v.contra("SB88", "the registration lists no lastUsed")
        elif a != b:
            self.v.confirm("SB88", "lastUsed moved between two reads %s s apart" % (2 if self.steady_s else 0))
        else:
            since = "and since the first read %.0f s earlier" % (self.client.clock() - self.lastused0_at)
            moved = self.lastused0 != b
            self.v.contra(
                "SB88",
                "lastUsed did not move between two reads 2 s apart%s %s"
                % ("" if not moved else ", but did", since if moved else "(nor %s)" % since),
            )
        if not self.second:
            self.v.skip("SB86", HANDS["SB86"])
            return
        sid = self.second["id"]
        self.refuse("SB86", None, 401, 2, path="/registrations/%s" % sid, method="DELETE")
        self.v.check(
            "SB86",
            sid in (self.read().get("registrations") or {}),
            "another registration's token removes nothing",
            "registration %s is gone" % sid,
        )
        answer = self.req("DELETE", "/registrations/%s" % sid, token=self.second["token"])
        self.v.check(
            "SB86", answer.status == 200 and answer.body == {}, "DELETE with its own token → 200 {}", self.show(answer)
        )
        if answer.status == 200:
            self.refuse("SB86", None, 401, 2, path="/registrations", token=self.second["token"], method="GET")
            entry = self.store.box(self.box_id) or {}
            entry.pop("second", None)
            self.store.put(self.box_id, entry)

    # -- the whole run -----------------------------------------------------------------------------

    def begin(self):
        """The snapshot: GET /api/v1 with the token, learnt by the redactor and saved."""
        st = self.read()
        if st is None:
            raise ProbeError("GET /api/v1 with the probe's token was refused: run `forget`, then `register` again")
        self.snapshot = copy.deepcopy(st)
        self.redactor.learn(st, address=self.address or self.client.host, box_id=self.box_id)
        self.known_ids |= {str(k) for k in st.get("registrations") or {}}
        self.sample("start", st)
        return st

    def run_checks(self, only=None):
        only = set(only or ())
        for name, title, rules, fn in CHECKS:
            if only and not only & set(rules):
                continue
            if self.client.clock() - self.started > self.budget_s:
                for rule in rules:
                    self.v.skip(rule, "the run's time budget (%.0f s) ran out before %s" % (self.budget_s, title))
                continue
            before = {r: len(self.v.items.get(r, ())) for r in rules}
            try:
                fn(self)
            except Precondition as error:
                for rule in rules:
                    if len(self.v.items.get(rule, ())) == before[rule]:
                        self.v.skip(rule, "%s: %s" % (title, error))
            except ProbeError:
                raise
            finally:
                if name not in ("c_state", "c_paths", "c_auth", "c_methods"):
                    self.restore_settings()
            counts = {}
            for rule in rules:
                for entry in self.v.items.get(rule, ())[before[rule] :]:
                    counts[entry["verdict"]] = counts.get(entry["verdict"], 0) + 1
            self._log(
                "%s (%s): %s"
                % (title, " ".join(rules), ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items())) or "nothing")
            )

    def finish_invariants(self):
        texts = {
            "SB3": "syncActive is true exactly in a sync mode",
            "SB4": "hdmiActive is false exactly in powersave",
            "SB8": "no answer carried a token",
            "SB10": "every answer was JSON; each refusal had code, message and its code's status",
            "SB11": "every accepted PUT and DELETE answered {}",
            "SB90": "connectionState was one of the eight",
            "SB113": "uniqueId and deviceType never changed",
        }
        for rule, (good, bad, sample) in self.inv.items():
            if good + bad == 0:
                continue
            if bad:
                self.v.contra(rule, "%s: not in %d of %d, e.g. %s" % (texts[rule], bad, good + bad, sample))
            else:
                self.v.confirm(rule, "%s (%d answers or reads)" % (texts[rule], good))

    def save_fixtures(self, extra=None):
        out = os.path.join(self.out_dir, "fixtures")
        r = self.redactor
        files = {"device_unkeyed.json": getattr(self, "unkeyed_device", None), "errors.json": self.errors or None}
        for name, state in self.samples.items():
            files["state_%s.json" % name] = state
        if self.snapshot:
            files["registrations.json"] = self.snapshot.get("registrations")
            files["device.json"] = self.snapshot.get("device")
        files.update(extra or {})
        for name, data in files.items():
            if data is not None:
                _write_json(os.path.join(out, name), r.json(data))
        return out

    def prompt(self, step, phase, text):
        self._log(">>> %s" % text)
        if self.on_prompt:
            self.on_prompt(step, phase)


# -- hands-on steps ----------------------------------------------------------------------------------

HANDS_STEPS = {
    1: (
        "Hold the box's button about 3 s (LED blinks green), and again when the probe asks, about 10 s later",
        "register --twice",
        ("SB82", "SB85", "SB84", "SB86"),
    ),
    2: (
        "Turn the source on input K off with its own remote, then on again when the probe asks",
        "hands --step 2",
        ("SB63", "SB70", "SB72", "SB73", "SB74", "SB78"),
    ),
    3: (
        "Pull the HDMI cable of the source on input K out of the box, then push it back when the probe asks",
        "hands --step 3",
        ("SB71", "SB72"),
    ),
    4: (
        "Pull the Hue Bridge's network cable (power stays on) while the box syncs, plug it back when the probe asks",
        "hands --step 4",
        ("SB56", "SB91", "SB93"),
    ),
    5: ("Restart the box from the Hue Sync app", "hands --step 5", ("SB120",)),
}


def _linked_input(run, st, given=None, want="linked"):
    if given:
        if given not in run.inputs:
            raise ProbeError("no %s on this box (it has %s)" % (given, ", ".join(run.inputs)))
        return given
    statuses = {k: dig(st, "hdmi.%s.status" % k) for k in run.inputs}
    order = [run.source0] + [k for k in run.inputs if k != run.source0]
    for k in order:
        if statuses.get(k) == want:
            return k
    raise ProbeError("no input reads %s: switch a source on (its picture on the TV) or name one with --input" % want)


def hands_source(run, given=None):
    """Step 2: a source's CEC Active Source and its link going and coming."""
    st = run.ensure("passthrough")
    k = _linked_input(run, st, given)
    other = run.other_input(k)
    behavior = st.get("behavior") or {}
    flags = {
        f: v
        for f, v in (("cecInputSwitch", 1), ("linkAutoSync", 1), ("hpdInputPortSwitch", 0))
        if f in (behavior.get(k) or {})
    }
    body = {k: flags}
    if "hpdInputSwitch" in behavior:
        body["hpdInputSwitch"] = 0
    run.prep(body, "/behavior")
    run.prep({"hdmiSource": k})
    last = dig(run.state, "hdmi.%s.lastSyncMode" % k)
    synced = True
    try:
        run.ensure(last if last in SYNC_MODES else "video", k)
    except Precondition as error:
        synced = False
        run.v.skip("SB74", "the box would not sync on %s: %s" % (k, error))
    run.prompt(2, "off", "Turn the source on %s OFF with its own remote now (standby)." % k)
    held, st = run.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) != "linked", timeout=run.hands_wait_s)
    if not held:
        for rule in ("SB74", "SB78"):
            run.v.skip(rule, "%s still read linked after %.0f s" % (k, run.hands_wait_s))
    else:
        run.v.confirm("SB72", "%s went from linked to %s as its source went off" % (k, dig(st, "hdmi.%s.status" % k)))
        if synced:
            held, st = run.wait_for(lambda s: mode_of(s) == "passthrough", timeout=10.0)
            run.v.check(
                "SB74", held, "the sync on %s ended when it stopped reading linked" % k, "mode %s" % mode_of(st)
            )
        run._sample78()
    if other:
        run.prep({"hdmiActive": False, "hdmiSource": other}, until=lambda s: mode_of(s) == "powersave")
        where = "in powersave on %s" % other
    else:
        run.prep({"hdmiActive": False}, until=lambda s: mode_of(s) == "powersave")
        where = "in powersave"
    run.prompt(2, "on", "Now turn the source on %s ON again with its remote (the box waits %s)." % (k, where))
    held, st = run.wait_for(
        lambda s: dig(s, "execution.hdmiSource") == k and mode_of(s) != "powersave", timeout=run.hands_wait_s
    )
    if held:
        run.v.confirm(
            "SB70", "CEC Active Source from %s: the box %s selected it and woke (%s)" % (k, where, mode_of(st))
        )
        run.v.confirm("SB63", "the switch followed cecInputSwitch 1 written just before the event")
        held, st = run.wait_for(
            lambda s: mode_of(s) in SYNC_MODES and dig(s, "hdmi.%s.status" % k) == "linked", timeout=20.0
        )
        run.v.check(
            "SB73",
            held,
            "with linkAutoSync 1 the box synced once %s and the output linked" % k,
            "mode %s, %s %s, output %s"
            % (mode_of(st), k, dig(st, "hdmi.%s.status" % k), dig(st, "hdmi.output.status")),
        )
        held, st = run.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) == "linked", timeout=10.0)
        if held:
            run.v.confirm("SB72", "%s reads linked again once awake" % k)
            run._sample78()
    else:
        why = "no switch to %s within %.0f s (box %s on %s, %s reads %s): does the source send CEC Active Source?" % (
            k,
            run.hands_wait_s,
            mode_of(st),
            dig(st, "execution.hdmiSource"),
            k,
            dig(st, "hdmi.%s.status" % k),
        )
        for rule in ("SB70", "SB63", "SB73"):
            run.v.skip(rule, why)


def hands_hotplug(run, given=None):
    """Step 3: a source's cable out and in (hot plug)."""
    st = run.ensure("passthrough")
    try:
        k = _linked_input(run, st, given)
    except ProbeError:
        k = _linked_input(run, st, given, want="plugged")
    other = run.other_input(k)
    behavior = st.get("behavior") or {}
    flags = {
        f: v
        for f, v in (("cecInputSwitch", 0), ("linkAutoSync", 0), ("hpdInputPortSwitch", 1))
        if f in (behavior.get(k) or {})
    }
    body = {k: flags}
    if "hpdInputPortSwitch" not in flags:
        if "hpdInputSwitch" not in behavior:
            raise ProbeError("this box has no hot-plug switching (hpdInputSwitch, hpdInputPortSwitch)")
        body["hpdInputSwitch"] = 1
    run.prep(body, "/behavior")
    if other is None:
        raise ProbeError("a one-input box cannot show a switch to the plugged input")
    run.prep({"hdmiActive": False, "hdmiSource": other}, until=lambda s: mode_of(s) == "powersave")
    run.prompt(3, "out", "Pull the HDMI cable of the source on %s OUT of the box now." % k)
    held, st = run.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) == "unplugged", timeout=run.hands_wait_s)
    if not held:
        run.v.skip("SB71", "%s never read unplugged within %.0f s" % (k, run.hands_wait_s))
        return
    run.v.confirm("SB72", "%s reads unplugged with its cable out" % k)
    run.prompt(3, "in", "Push the cable back IN to %s now (the box waits in powersave on %s)." % (k, other))
    held, st = run.wait_for(lambda s: dig(s, "hdmi.%s.status" % k) in ("plugged", "linked"), timeout=run.hands_wait_s)
    if not held:
        run.v.skip("SB71", "%s did not read plugged within %.0f s" % (k, run.hands_wait_s))
        return
    run.v.confirm("SB71", "%s reads %s once plugged in" % (k, dig(st, "hdmi.%s.status" % k)))
    held, st = run.wait_for(lambda s: dig(s, "execution.hdmiSource") == k and mode_of(s) != "powersave", timeout=20.0)
    run.v.check(
        "SB71",
        held,
        "with hot-plug switching on, the box selected %s and woke" % k,
        "mode %s on %s" % (mode_of(st), dig(st, "execution.hdmiSource")),
    )


def hands_bridge(run, given=None):
    """Step 4: the bridge link lost while syncing, then back."""
    del given
    if not run.bridge_mode:
        raise ProbeError("this box runs without a bridge")
    run.ensure("video", run.source0)
    held, _ = run.wait_for(lambda s: dig(s, "hue.connectionState") == "streaming")
    if not held:
        raise ProbeError("the box does not stream to its area: nothing to lose")
    run.prompt(4, "pull", "Pull the Hue Bridge's NETWORK cable now (leave its power on).")
    held, st = run.wait_for(
        lambda s: dig(s, "hue.connectionState") not in ("streaming", "connected"), timeout=run.hands_wait_s
    )
    if not held:
        for rule in ("SB56", "SB91", "SB93"):
            run.v.skip(rule, "the link still read %s after %.0f s" % (dig(st, "hue.connectionState"), run.hands_wait_s))
        return
    state = dig(st, "hue.connectionState")
    held, st = run.wait_for(lambda s: mode_of(s) == "passthrough", timeout=10.0)
    groups = dig(st, "hue.groups") or {}
    inactive = all(not (g or {}).get("active") for g in groups.values()) or state == "busy"
    run.v.check(
        "SB93",
        held and inactive,
        "link %s while syncing: the sync ended (passthrough), every area inactive" % state,
        "mode %s, active areas %d" % (mode_of(st), sum(1 for g in groups.values() if (g or {}).get("active"))),
    )
    run.refuse("SB91", {"syncActive": True}, 400, 16)
    b = dig(run.read(), "execution.brightness", 100)
    nb = b + 10 if b <= 190 else b - 10
    run.refuse("SB56", {"brightness": nb, "syncActive": True}, 400, 16)
    got = dig(run.read(), "execution.brightness")
    run.v.check("SB56", got == b, "the refused PUT applied none of its fields", "brightness %s" % got)
    answer = run.put({"mode": "video", "syncActive": False})
    st = run.read()
    run.v.check(
        "SB56",
        answer.status == 200 and mode_of(st) == "passthrough",
        "{mode: video, syncActive: false} is judged on its result (passthrough) and taken",
        "%s, mode %s" % (run.show(answer), mode_of(st)),
    )
    run.prompt(4, "plug", "Plug the bridge's network cable back IN now.")
    held, st = run.wait_for(
        lambda s: dig(s, "hue.connectionState") in ("connected", "streaming"), timeout=run.hands_wait_s
    )
    if not held:
        run.v.skip("SB91", "the link did not come back within %.0f s" % run.hands_wait_s)
        return
    groups = dig(st, "hue.groups") or {}
    run.v.check(
        "SB93",
        mode_of(st) == "passthrough" and not any((g or {}).get("active") for g in groups.values()),
        "link connected again: the box stays in passthrough, no area active",
        "mode %s" % mode_of(st),
    )
    run.put({"syncActive": True})
    held, st = run.wait_for(lambda s: mode_of(s) in SYNC_MODES and dig(s, "hue.connectionState") == "streaming")
    run.v.check("SB91", held, "once connected again {syncActive: true} syncs and streams", "mode %s" % mode_of(st))


def hands_restart(run, given=None):
    """Step 5: a restart from the Hue Sync app: how long nothing answers, and what is kept."""
    del given
    before = copy.deepcopy(run.read())
    clock = run.client.clock
    run.prompt(5, "restart", "Restart the box from the Hue Sync app now.")
    start, down, up = clock(), None, None
    while clock() - start < run.hands_wait_s:
        answer = run.client.request("GET", "/device")
        if answer.status is None:
            down = clock()
            break
        run.client.sleep(run.poll_s)
    if down is None:
        run.v.skip("SB120", "the box kept answering for %.0f s" % run.hands_wait_s)
        return
    run.client.close()
    while clock() - down < 300:
        answer = run.client.request("GET", "/device")
        if answer.status == 200:
            up = clock()
            break
        run.client.sleep(run.poll_s)
    if up is None:
        run.v.contra("SB120", "the box did not answer again within 300 s")
        return
    silence = up - down
    lo, hi = run.restart_silence_s
    run.v.check(
        "SB120",
        lo <= silence <= hi,
        "nothing answered for %.0f s (the fakes: 30 s)" % silence,
        "measured %.1f s" % silence,
    )
    after = run.read()
    if after is None:
        run.v.contra("SB120", "the probe's token is refused after the restart")
        return
    diffs = restore_diff(before, after)
    regs = sorted(before.get("registrations") or {}) == sorted(after.get("registrations") or {})
    run.v.check(
        "SB120",
        not diffs and regs,
        "after the restart the state, registrations and token are as before",
        "; ".join("%s %s → %s" % d for d in diffs[:6]) + ("" if regs else "; registrations changed"),
    )


HANDS_FNS = {2: hands_source, 3: hands_hotplug, 4: hands_bridge, 5: hands_restart}


# -- the report ---------------------------------------------------------------------------------------


def behaviour_rules(path=BEHAVIOUR):
    """[(rule, assumed)] in the document's order."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return []
    out = []
    for match in re.finditer(r"^- \*\*(SB\d+)\*\* (.*?)(?=^- \*\*SB|^#|\Z)", text, re.S | re.M):
        out.append((match.group(1), "assumed" in match.group(2)))
    return out


def merge_hands(out_dir, verdicts, source):
    """Replace `source`'s entries in hands.json with these (rule -> entries)."""
    path = os.path.join(out_dir, "hands.json")
    data = _read_json(path, {"version": 1, "verdicts": {}})
    for rule in list(data["verdicts"]):
        data["verdicts"][rule] = [e for e in data["verdicts"][rule] if e.get("source") != source]
        if not data["verdicts"][rule]:
            del data["verdicts"][rule]
    for rule, entries in verdicts.items():
        for entry in entries:
            data["verdicts"].setdefault(rule, []).append(dict(entry, source=source, time=iso_now()))
    _write_json(path, data)
    return data


def write_report(out_dir, report_path=None):
    """report.md from run.json and hands.json; returns its path and the per-rule verdicts."""
    run = _read_json(os.path.join(out_dir, "run.json"), {})
    hands = _read_json(os.path.join(out_dir, "hands.json"), {}).get("verdicts", {})
    entries = {}
    for rule, items in (run.get("verdicts") or {}).items():
        entries.setdefault(rule, []).extend(items)
    for rule, items in hands.items():
        entries.setdefault(rule, []).extend(items)
    rules = behaviour_rules() or [(r, False) for r in sorted(entries, key=lambda r: int(r[2:]))]
    final = {}
    lines = [
        "# Sync box conformance (#547)",
        "",
        "The rules of `docs/syncbox-behaviour.md` against a real box: `tools/fakebox/conformance.py`.",
        "Every address, id, name and token is replaced by a placeholder.",
        "",
    ]
    meta = run.get("meta") or {}
    if meta:
        lines += [
            "- Box: %s, firmware %s, API level %s" % (meta.get("model"), meta.get("firmware"), meta.get("apiLevel")),
            "- Run: %s, %s requests in %.0f s%s"
            % (
                meta.get("time"),
                meta.get("requests"),
                meta.get("seconds", 0),
                ", only %s" % " ".join(meta["only"]) if meta.get("only") else "",
            ),
            "- Restore: %s" % (meta.get("restore") or "complete, checked by reading the box again"),
            "",
        ]
    counts = {}
    rows = []
    for rule, assumed in rules:
        items = entries.get(rule, [])
        verdict = combine(items)
        if verdict == "not checked" and not items:
            why = HANDS.get(rule) or NOT_PROBED.get(rule) or "no check (shown by its sources)"
            items = [{"verdict": "not checked", "detail": why, "source": "-"}]
        final[rule] = verdict
        counts[verdict] = counts.get(verdict, 0) + 1
        wanted = [e for e in items if e["verdict"] == verdict] or items
        sources = sorted({e.get("source", "run") for e in wanted})
        detail = "; ".join(dict.fromkeys(e["detail"] for e in wanted))
        detail = detail if len(detail) <= 400 else detail[:400] + "..."
        rows.append(
            "| %s | %s | %s | %s | %s |"
            % (rule, "yes" if assumed else "", verdict, ", ".join(sources), detail.replace("|", "\\|"))
        )
    lines += ["%s: %s" % ("Verdicts", ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))), ""]
    lines += ["| Rule | Assumed | Verdict | From | Detail |", "| --- | --- | --- | --- | --- |"] + rows + [""]
    path = report_path or os.path.join(out_dir, "report.md")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))
    return path, final


# -- the commands -------------------------------------------------------------------------------------


def register(
    client,
    store,
    *,
    twice=False,
    wait_s=REGISTER_WAIT_S,
    every_s=REGISTER_EVERY_S,
    log=print,
    on_wait=None,
    out_dir=DEFAULT_OUT,
):
    """`register`: the identity first, then POST /registrations until the button is pressed (once, or twice
    with --twice). Returns the box id."""
    run = Run(client, None, out_dir=out_dir, log=log)
    box_id = run.identify(require_registration=False)
    entry = store.box(box_id) or {}
    others = [b for b in store.boxes() if b != box_id]
    if others:
        log("probe.json also holds %d other box(es); this one is added" % len(others))
    if entry.get("token"):
        answer = client.request("GET", "/registrations", token=entry["token"])
        if answer.status == 200:
            if not twice or entry.get("second"):
                log("the probe is registered with this box already (forget first to register again)")
                return box_id
        else:
            log("the stored registration is refused (%s): registering again" % run.show(answer))
            entry = {}
    verdicts = Verdicts(run.redactor, source="hands step 1", log=run._log)
    wanted = ["first", "second"] if twice else ["first"]
    if entry.get("token"):
        wanted = ["second"]
    for which in wanted:
        log(
            ">>> Hold the box's button about 3 seconds, until its LED blinks green%s (the probe tries for %.0f s)."
            % (" (the second press: the same names again)" if which == "second" else "", wait_s)
        )
        if on_wait:
            on_wait(which)
        body = {"appName": APP_NAME, "instanceName": INSTANCE_NAME}
        start, answer = client.clock(), None
        while True:
            answer = client.request("POST", "/registrations", body=body)
            if answer.status == 200 or answer.code != 16 or client.clock() - start >= wait_s:
                break
            client.sleep(every_s)
        if answer.status != 200 or not isinstance(answer.body, dict) or not answer.body.get("accessToken"):
            raise ProbeError("no registration: %s" % run.show(answer))
        token, reg_id = answer.body["accessToken"], str(answer.body.get("registrationId"))
        run.redactor.secret(token)
        record = {"registration": reg_id, "token": token}
        if which == "first":
            entry = dict(record, created=iso_now())
        else:
            entry["second"] = record
        store.put(box_id, entry)
        log("registered (%s registration %s); the token is in %s" % (which, reg_id, store.path))
        again = client.request("POST", "/registrations", body=body)
        if again.status == 200 and isinstance(again.body, dict) and again.body.get("accessToken"):
            verdicts.contra("SB82", "one press made two registrations")
            run.own_ids.add(str(again.body.get("registrationId")))
            client.request(
                "DELETE", "/registrations/%s" % again.body.get("registrationId"), token=again.body["accessToken"]
            )
        else:
            verdicts.check(
                "SB82",
                again.status == 400 and again.code == 16,
                "a second POST right after the %s registration → 16: one per press" % which,
                run.show(again),
            )
    merge_hands(out_dir, verdicts.items, "hands step 1")
    write_report(out_dir)
    return box_id


def forget(client, store, *, log=print, out_dir=DEFAULT_OUT):
    """`forget`: DELETE the probe's registrations (each with its own token) and its probe.json entry."""
    run = Run(client, store, out_dir=out_dir, log=log)
    box_id = run.identify(require_registration=False)
    entry = store.box(box_id)
    if not entry:
        log("the probe holds no registration for this box")
        return 0
    for record in [entry.get("second"), entry]:
        if isinstance(record, dict) and record.get("token"):
            run.redactor.secret(record["token"])
            answer = client.request("DELETE", "/registrations/%s" % record.get("registration"), token=record["token"])
            log("registration %s: %s" % (record.get("registration"), run.show(answer)))
    store.put(box_id, None)
    log("removed this box from %s" % store.path)
    return 0


def run_probe(client, store, *, only=None, out_dir=DEFAULT_OUT, report=None, log=print, **options):
    """`run`: identity, snapshot, checks, restore, report. Returns (exit code, {rule: verdict}, Run)."""
    run = Run(client, store, out_dir=out_dir, log=log, **options)
    run.identify()
    snapshot = run.begin()
    run._log(
        "snapshot taken: %s on %s, %d inputs, %d areas; the lights will change while it runs"
        % (mode_of(snapshot), dig(snapshot, "execution.hdmiSource"), len(run.inputs), len(run.areas))
    )
    restore, code = None, 0
    try:
        run.run_checks(only)
    except KeyboardInterrupt:
        code = 130
        run._log("interrupted: restoring")
    finally:
        diffs = run.restore_all()
        restore = None if not diffs else "INCOMPLETE: " + "; ".join("%s %s → %s" % d for d in diffs)
        run._log("restore %s" % ("checked: the box reads as before" if not diffs else run.redactor.text(restore)))
        run.finish_invariants()
        run.sample("end", run.read())
        run.save_fixtures()
        only_rules = sorted(set(only or ()), key=lambda r: int(r[2:]) if r[2:].isdigit() else 0)
        meta = {
            "model": run.model,
            "firmware": dig(snapshot, "device.firmwareVersion"),
            "apiLevel": run.level,
            "time": iso_now(),
            "requests": client.count,
            "seconds": round(client.clock() - run.started, 1),
            "only": only_rules,
            "restore": run.redactor.text(restore) if restore else None,
        }
        verdicts = run.v.items
        if only:
            verdicts = {r: e for r, e in verdicts.items() if r in set(only)}
        _write_json(os.path.join(out_dir, "run.json"), {"version": 1, "meta": meta, "verdicts": verdicts})
        path, final = write_report(out_dir, report)
        run._log("report: %s" % path)
    if restore and code == 0:
        code = 1
    return code, final, run


def hands_probe(client, store, step, *, given=None, out_dir=DEFAULT_OUT, log=print, **options):
    """`hands --step N`: one hands-on step. Returns (exit code, {rule: [entries]}, Run)."""
    if step not in HANDS_FNS:
        raise ProbeError("hands-on steps are 2 to 5 here; step 1 is `register --twice`")
    run = Run(client, store, out_dir=out_dir, log=log, **options)
    run.v.source = "hands step %d" % step
    run.identify()
    run.begin()
    run._log("hands-on step %d: %s" % (step, HANDS_STEPS[step][0]))
    code = 0
    try:
        HANDS_FNS[step](run, given)
    except Precondition as error:
        run._log("step %d could not be set up: %s" % (step, error))
        code = 1
    except KeyboardInterrupt:
        code = 130
    finally:
        diffs = run.restore_all()
        if diffs:
            run._log("restore INCOMPLETE: %s" % run.redactor.text("; ".join("%s %s → %s" % d for d in diffs)))
            code = code or 1
        else:
            run._log("restore checked: the box reads as before")
        merge_hands(out_dir, run.v.items, "hands step %d" % step)
        path, _ = write_report(out_dir)
        run._log("report: %s" % path)
    return code, run.v.items, run


def normalise_only(values):
    """--only's rules as SB<n>: "sb42", "42" and "SB42" alike; None when not given."""
    if not values:
        return None
    out = []
    for value in values:
        for part in re.split(r"[,\s]+", str(value)):
            digits = re.sub(r"^(?i:sb)", "", part)
            if digits.isdigit():
                out.append("SB%d" % int(digits))
            elif part:
                raise ProbeError("--only takes rules like SB42, not %r" % part)
    return out


def build_parser():
    parser = argparse.ArgumentParser(
        prog="conformance.py",
        description="Check docs/syncbox-behaviour.md's rules against a real Hue Play HDMI Sync Box (#547). "
        "VISIBLE CHANGES: run and hands switch the box between powersave, passthrough and the sync modes, inputs "
        "and areas, so the lights and the TV picture change while they run (another entertainment area's lights may "
        "sync for a moment); everything is put back at the end and checked.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p, address=True):
        if address:
            p.add_argument("--address", required=True, help="the box's address (host or host:port)")
            p.add_argument("--port", type=int, default=None, help="the box's port (default 443)")
        tests = p.add_argument_group("test options (the Python fake box)")
        tests.add_argument("--cafile", default=DEFAULT_CAFILE, help="the root to trust (default the box's pinned root)")
        tests.add_argument("--probe-file", default=DEFAULT_PROBE_FILE, help="where the tokens are kept")
        tests.add_argument(
            "--out", default=DEFAULT_OUT, help="report, fixtures and verdicts (default build/conformance)"
        )
        tests.add_argument("--pace-ms", type=int, default=int(PACE_S * 1000), help="the least time between requests")

    p = sub.add_parser("register", help="register the probe while the owner presses the box's button")
    p.add_argument("--twice", action="store_true", help="then wait for a second press (SB85, SB86)")
    p.add_argument("--wait", type=float, default=REGISTER_WAIT_S, help="seconds to wait for each press")
    common(p)
    p = sub.add_parser("run", help="every check that needs no hands (the lights change while it runs)")
    p.add_argument("--only", nargs="+", metavar="SB", help="only the checks of these rules")
    p.add_argument("--report", help="the report's path (default <out>/report.md)")
    p.add_argument("--budget", type=float, default=BUDGET_S, help="seconds after which no check starts")
    common(p)
    p = sub.add_parser("hands", help="one hands-on step (2 to 5): set up, say what to do, read the box")
    p.add_argument("--step", type=int, help="the step")
    p.add_argument("--list", action="store_true", help="list the steps")
    p.add_argument("--input", help="the input of the source for steps 2 and 3 (default the one that reads linked)")
    p.add_argument("--wait", type=float, default=HANDS_WAIT_S, help="seconds to wait for each action")
    p.add_argument("--address", help="the box's address (host or host:port)")
    p.add_argument("--port", type=int, default=None, help="the box's port (default 443)")
    common(p, address=False)
    p = sub.add_parser("forget", help="delete the probe's registrations and its tokens")
    common(p)
    p = sub.add_parser("report", help="write the report again")
    p.add_argument("--report", help="the report's path (default <out>/report.md)")
    p.add_argument("--out", default=DEFAULT_OUT, help="report, fixtures and verdicts (default build/conformance)")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)

    def log(text):
        print(text, flush=True)

    if args.cmd == "report":
        path, final = write_report(args.out, args.report)
        counts = {}
        for verdict in final.values():
            counts[verdict] = counts.get(verdict, 0) + 1
        log("%s: %s" % (path, ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items()))))
        return 0
    if args.cmd == "hands" and (args.list or not args.step):
        for n, (action, command, rules) in sorted(HANDS_STEPS.items()):
            log("%d. %s  [%s; settles %s]" % (n, action, command, " ".join(rules)))
        return 0 if args.list else 2
    if not getattr(args, "address", None):
        log("conformance.py: --address is needed")
        return 2
    host, port = split_address(args.address, args.port)
    try:
        client = BoxClient(host, port, cafile=args.cafile, pace_s=max(0, args.pace_ms) / 1000.0)
        store = Store(args.probe_file)
        if args.cmd == "register":
            register(client, store, twice=args.twice, wait_s=args.wait, log=log, out_dir=args.out)
            return 0
        if args.cmd == "forget":
            return forget(client, store, log=log, out_dir=args.out)
        if args.cmd == "run":
            code, final, _ = run_probe(
                client,
                store,
                only=normalise_only(args.only),
                out_dir=args.out,
                report=args.report,
                log=log,
                budget_s=args.budget,
                address=host,
            )
            counts = {}
            for verdict in final.values():
                counts[verdict] = counts.get(verdict, 0) + 1
            log("verdicts: %s" % ", ".join("%d %s" % (n, k) for k, n in sorted(counts.items())))
            return code
        code, _, _ = hands_probe(
            client, store, args.step, given=args.input, out_dir=args.out, log=log, hands_wait_s=args.wait, address=host
        )
        return code
    except ProbeError as error:
        print("conformance.py: %s" % error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
