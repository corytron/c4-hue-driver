"""The fake Hue Sync Box's state machine (#547, docs/fakebox-design.md §2): pure, no I/O, no threads.

The box is the GET /api/v1 document of docs/syncbox-api-research.md (R1) §2.4 (device, execution, hdmi,
behavior, hue, ir, registrations, presets), starting from a fixture of tests/fixtures/hue_syncbox.json
(generated from tests/fixtures/hue_syncbox.lua, so the Lua fake and this one start from the same
bodies). The rules are those of docs/syncbox-behaviour.md, cited as SB<n> in each docstring with R1's
section where R1 shows the fact; SB<n> marks which are [assumed] and the house check that settles
each. Field names only: nothing here is copied from Signify's reference or from a library.

API
  load_fixtures(path=None) -> dict        tests/fixtures/hue_syncbox.json, decoded
  Box(fixture, clock=None, **options)     fixture: a GET /api/v1 document (dict, deep-copied) or the
                                          name of one in the fixtures (HSB1, HSB2, HSB3,
                                          HSB3_standalone, HSB2_behind_receiver, HSB2_second_output)
    options: box_id (device.uniqueId), address (device.ipAddress), device (the unkeyed GET /device
             body, else made from the state as it is), registrations ({id: token} or {id: {token,
             appName, instanceName, role}}: paired already), token_factory (fn(id) -> token; default
             the placeholders of SB83), pairing_window_ms, reboot_ms, fixtures (a load_fixtures())
  box.request(method, path, headers=None, body=None) -> (status, body)
      path "/api/v1..." or the part after /api/v1 ("" and "/execution" alike); headers a mapping
      (Authorization: Bearer <token>); body text, bytes, None or an already-decoded object. The answer
      is a dict: the state asked for, {} after a write (SB11), {"code", "message"} on a refusal (SB10).
      (None, None) while the box restarts: no answer at all (SB120; the server closes its port).
  box.event(name, **args)                 the events of EVENTS (below); ValueError on a bad argument
  box.state() -> dict                     the whole GET /api/v1 answer now, without counting as a
                                          request (SB72's masking applied, no tokens; §12 "The view")
  box.get(path) / box.set(path, value) / box.unset(path)   a dotted path, as the Hue Sync app would
  box.status() -> dict                    what the document does not show: the pairing window, the
                                          restart, the registrations' ids, the clock
  box.history                             what the box did and why, newest last
  auth(token) -> headers                  {"Authorization": "Bearer <token>"}

Clocks (docs/syncbox-behaviour.md §12): milliseconds. ManualClock moves only on the "advance" event
(the tests' and the scenarios'); ScaledClock is wall time times --time-scale plus whatever "advance"
adds (the server's). Only the pairing window (SB82), the restart (SB120) and the times written by SB49
and SB88 read it; idle time passes only through the "idle" event (SB77).

Events (contract §4; arguments by name):
  button [window]                 the link button held: one registration within 5 s (SB82); window in s
  cec_active_source input         a source sends CEC Active Source (SB70)
  hotplug input                   a source is plugged in or powers on (SB71)
  signal input status             a port's status (input<n> or output) (SB72, SB74, SB78)
  tv_standby                      the TV's CEC standby (SB75)
  usb_power_lost                  the TV's USB port loses its 5 V (SB76)
  idle minutes                    that much idle time (SB77)
  bridge state                    hue.connectionState (SB90, SB92, SB93)
  rename name                     renamed in the Hue Sync app (SB112)
  app_deletes registration        a registration deleted in the app (SB87)
  firmware version api_level      a firmware update and its restart (SB121, SB122)
  reboot                          30 s without an answer, then the same state (SB120)
  advance ms                      the clock moves on (§12)
  address address                 the box's address changes (SB114)
  operating_mode mode             bridge or standalone (R1 §1.5; not in the scenarios)
An input the model lacks makes cec_active_source, hotplug and signal do nothing (SB70).
"""

import copy
import json
import os
import re
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES_JSON = os.path.join(ROOT, "tests", "fixtures", "hue_syncbox.json")

# R1 §2.6 (SB30, SB38, SB44, SB47).
MODES = ("powersave", "passthrough", "video", "game", "music")
SYNC_MODES = ("video", "game", "music")
SYNC_CYCLE = ("video", "music", "game")  # cycleSyncMode's order (SB38)
INTENSITIES = ("subtle", "moderate", "high", "intense")
PALETTES = ("happyEnergetic", "happyCalm", "melancholicCalm", "melancholicEnergetic", "neutral")
DIRECTIONS = ("next", "previous")
# R1 §2.7: the 26 port types and the four statuses (SB72, SB100).
PORT_TYPES = (
    "generic", "video", "game", "music", "xbox", "playstation", "nintendoswitch", "phone", "desktop",
    "laptop", "appletv", "roku", "shield", "chromecast", "firetv", "diskplayer", "settopbox", "satellite",
    "avreceiver", "soundbar", "hdmiswitch", "tv", "monitor", "beamer", "speaker", "hdmisplitter",
)  # fmt: skip
PORT_STATUSES = ("unplugged", "plugged", "linked", "unknown")
# R1 §2.9 (SB90): the states a "bridge" event sets.
CONNECTION_STATES = ("uninitialized", "disconnected", "connecting", "unauthorized", "connected", "invalidgroup", "busy")
OPERATING_MODES = ("bridge", "standalone", "uninitialized")

# The unkeyed GET /device (SB12): the fixture's unkeyed fields.
UNKEYED_DEVICE_FIELDS = (
    "name", "deviceType", "uniqueId", "ipAddress", "apiLevel", "firmwareVersion", "buildNumber", "wifiState",
    "capabilities", "termsAgreed", "beta",
)  # fmt: skip

# Each refusal's HTTP status, code and message (SB10; the fixture's M.error and M.error_status, which
# replace these when given).
ERRORS = {
    "unauthorized": (401, 2, "Invalid Token"),
    "invalid_json": (400, 12, "Invalid JSON"),
    "invalid_key": (400, 13, "Invalid Key"),
    "invalid_value": (400, 15, "Invalid Value"),
    "invalid_state": (400, 16, "Invalid State"),
    "not_found": (404, 10, "Not Found"),
}

# Placeholders (CLAUDE.md "Licensing"; the fixture's TOKEN and REGISTRATION_ID, SB83).
TOKEN = "TEST-TOKEN-NOT-REAL"
WRONG_TOKEN = "WRONG-TOKEN-NOT-REAL"  # what the scenarios' token "wrong" sends (§14)
FIRST_REGISTRATION_ID = 7

PAIRING_WINDOW_MS = 5000  # SB82
REBOOT_MS = 30000  # SB120
DEFAULT_SPECS = "1920 x 1080 @ 60000 - SDR"  # SB78
OTHER_APP = "other-app"  # SB92: the owner of another app's stream
HISTORY_MAX = 1000

# PUT /execution's keys (R1 §2.6, SB30-SB51) and how each value is checked.
EXECUTION_KEYS = {
    "mode": ("enum", MODES),
    "syncActive": ("bool",),
    "hdmiActive": ("bool",),
    "hdmiSource": ("input",),
    "hueTarget": ("area",),
    "brightness": ("int", 0, 200),
    "incrementBrightness": ("int", -200, 200),
    "toggleSyncActive": ("bool",),
    "toggleHdmiActive": ("bool",),
    "cycleSyncMode": ("enum", DIRECTIONS),
    "cycleHdmiSource": ("enum", DIRECTIONS),
    "cycleIntensity": ("enum", DIRECTIONS),
    "toggleSyncMode": ("enum", SYNC_MODES),
    "intensity": ("enum", INTENSITIES),
    "backgroundLighting": ("bool",),
    "toggleBackgroundLighting": ("bool",),
    "preset": ("preset",),
    "video": ("object",),
    "game": ("object",),
    "music": ("object",),
}
HDMI_KEYS = ("hdmiActive", "hdmiSource", "toggleHdmiActive", "cycleHdmiSource")
MODE_OBJECT_KEYS = {  # SB47
    "video": {"intensity": ("enum", INTENSITIES), "backgroundLighting": ("bool",)},
    "game": {"intensity": ("enum", INTENSITIES), "backgroundLighting": ("bool",)},
    "music": {"intensity": ("enum", INTENSITIES), "palette": ("enum", PALETTES)},
}
# behavior's numbers and their ranges (SB60, SB61, SB62; hdrMode R1 §2.8); every other key is a flag.
BEHAVIOR_RANGES = {"inactivePowersave": (0, 10000), "hdrMode": (0, 2), "hpdOutputEnableMs": (0, 100000)}


class ManualClock:
    """Milliseconds that move only when told: the tests' and the scenarios' clock (§12)."""

    def __init__(self, start_ms=0):
        self._now = start_ms

    def now(self):
        return self._now

    def advance(self, ms):
        self._now += ms


class ScaledClock:
    """Wall time in milliseconds times `scale` (--time-scale), plus whatever advance() adds (§12)."""

    def __init__(self, scale=1.0, monotonic=time.monotonic):
        if not scale > 0:
            raise ValueError("the time scale must be above 0")
        self.scale = float(scale)
        self._monotonic = monotonic
        self._start = monotonic()
        self._offset = 0.0

    def now(self):
        return (self._monotonic() - self._start) * 1000.0 * self.scale + self._offset

    def advance(self, ms):
        self._offset += float(ms)


class BoxError(Exception):
    """A refusal: the HTTP status and the {"code", "message"} body (SB10)."""

    def __init__(self, status, code, message):
        super().__init__("%d code %d %s" % (status, code, message))
        self.status = status
        self.body = {"code": code, "message": message}


def load_fixtures(path=None):
    """tests/fixtures/hue_syncbox.json (or `path`), decoded: state.<name>, device.<name>, error, ..."""
    with open(path or FIXTURES_JSON, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("state"), dict):
        raise ValueError("%s: no state.<model> bodies" % (path or FIXTURES_JSON))
    return data


def auth(token):
    """The Authorization header of a keyed request (R1 §2.1)."""
    return {"Authorization": "Bearer %s" % token}


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _header(headers, name):
    """A header's value, its name matched without regard to case; None when absent."""
    if not headers:
        return None
    items = headers.items() if hasattr(headers, "items") else headers
    for key, value in items:
        if isinstance(key, str) and key.lower() == name:
            return value if isinstance(value, str) else str(value)
    return None


def bearer(headers):
    """(keyed, token): whether an Authorization header was sent, and its Bearer token or None."""
    value = _header(headers, "authorization")
    if value is None:
        return False, None
    match = re.match(r"^\s*bearer\s+(\S+)\s*$", value, re.I)
    return True, match.group(1) if match else None


def _port_name(value):
    """input<n> from 1, "1" or "input1"; output as is."""
    if _is_int(value):
        return "input%d" % value
    text = str(value)
    return "input" + text if text.isdigit() else text


def build_number(version):
    """SB121: major x 1000000 + minor x 10000 + patch x 100, as the fixtures make it."""
    parts = [int(p) for p in re.findall(r"\d+", str(version))[:3]] + [0, 0, 0]
    return parts[0] * 1000000 + parts[1] * 10000 + parts[2] * 100


class Box:
    """One sync box. See the module's docstring for the API; each rule's docstring cites its SB<n>."""

    def __init__(
        self,
        fixture,
        clock=None,
        *,
        box_id=None,
        address=None,
        device=None,
        registrations=None,
        token_factory=None,
        pairing_window_ms=PAIRING_WINDOW_MS,
        reboot_ms=REBOOT_MS,
        fixtures=None,
    ):
        if isinstance(fixture, str):
            fixtures = fixtures or load_fixtures()
            if fixture not in fixtures["state"]:
                raise ValueError("no fixture %r (have %s)" % (fixture, ", ".join(sorted(fixtures["state"]))))
            fixture = fixtures["state"][fixture]
        if not isinstance(fixture, dict) or not isinstance(fixture.get("device"), dict):
            raise ValueError("a fixture is a GET /api/v1 document with a device")
        self.clock = clock or ManualClock()
        self.history = []
        self.token_factory = token_factory
        self.pairing_window_ms = pairing_window_ms
        self.reboot_ms = reboot_ms
        self._errors = dict(ERRORS)
        for name, body in ((fixtures or {}).get("error") or {}).items():
            status = ((fixtures or {}).get("error_status") or {}).get(name)
            if isinstance(body, dict) and _is_int(body.get("code")) and _is_int(status):
                self._errors[name] = (status, body["code"], str(body.get("message", "")))
        doc = copy.deepcopy(fixture)
        if box_id:
            doc["device"]["uniqueId"] = str(box_id).upper()
        if address:
            doc["device"]["ipAddress"] = address
        self._device_override = copy.deepcopy(device) if device is not None else None
        # The signal the fixture shows (SB78): its text and flags, used whenever the selected input
        # reads linked.
        hdmi = doc.get("hdmi") if isinstance(doc.get("hdmi"), dict) else {}
        self._specs = hdmi.get("contentSpecs") or None
        self._spec_flags = (hdmi.get("videoSyncSupported", True), hdmi.get("audioSyncSupported", True))
        # Registrations by id: the fixture's (the Hue Sync app's; their tokens are not known, so none
        # works) and the given ones. The document lists them without tokens (SB8, SB84).
        self._regs = {}
        for reg_id, reg in (doc.get("registrations") or {}).items():
            entry = copy.deepcopy(reg) if isinstance(reg, dict) else {}
            entry["token"] = None
            self._regs[str(reg_id)] = entry
        doc.setdefault("registrations", {})
        self._doc = doc
        self._issued = 0
        self._highest = max([int(k) for k in self._regs if k.isdigit()] or [0])
        for reg_id, value in (registrations or {}).items():
            self.add_registration(reg_id, value)
        self._button_until = None
        self._down_until = None
        self._deferred = False

    # -- reading ------------------------------------------------------------------------------------

    def _now(self):
        return self.clock.now()

    def _stamp(self):
        """A time written into the state (SB49, SB88): the clock's milliseconds."""
        return int(round(self._now()))

    def state(self):
        """The whole GET /api/v1 answer now (SB1), without counting as a request (§12)."""
        self.tick()
        return self._view()

    def _read_status(self, port):
        """SB72: in powersave a linked port reads plugged."""
        status = ((self._doc.get("hdmi") or {}).get(port) or {}).get("status")
        if status == "linked" and (self._doc.get("execution") or {}).get("mode") == "powersave":
            return "plugged"
        return status

    def _view(self):
        view = copy.deepcopy(self._doc)
        view["registrations"] = {
            reg_id: {k: copy.deepcopy(v) for k, v in reg.items() if k != "token"} for reg_id, reg in self._regs.items()
        }
        hdmi = view.get("hdmi")
        if isinstance(hdmi, dict):
            for port in self._ports():
                hdmi[port]["status"] = self._read_status(port)
            linked = self._read_status((view.get("execution") or {}).get("hdmiSource")) == "linked"
            if "contentSpecs" in hdmi:
                hdmi["contentSpecs"] = (self._specs or DEFAULT_SPECS) if linked else ""
            flags = self._spec_flags if self._specs else (True, True)
            for key, flag in zip(("videoSyncSupported", "audioSyncSupported"), flags, strict=True):
                if key in hdmi:
                    hdmi[key] = bool(flag) if linked else False
        return view

    def get(self, path):
        """The value at a dotted path of state() ("execution.mode"); KeyError when absent."""
        node = self.state()
        for part in [p for p in str(path).split(".") if p]:
            if not isinstance(node, dict) or part not in node:
                raise KeyError(path)
            node = node[part]
        return node

    def status(self):
        """What the document does not show (the control API's state)."""
        self.tick()
        now = self._now()
        return {
            "now_ms": now,
            "pairing_open": self._button_until is not None,
            "pairing_left_ms": max(0, self._button_until - now) if self._button_until is not None else None,
            "restarting": self._down_until is not None,
            "restart_left_ms": max(0, self._down_until - now) if self._down_until is not None else None,
            "registrations": sorted(self._regs, key=lambda k: (len(k), k)),
            "paired": sorted((k for k, r in self._regs.items() if r.get("token")), key=lambda k: (len(k), k)),
        }

    def available(self):
        """False while the box restarts (SB120)."""
        self.tick()
        return self._down_until is None

    @property
    def box_id(self):
        return str(self._doc["device"].get("uniqueId", ""))

    @property
    def model(self):
        return str(self._doc["device"].get("deviceType", ""))

    @property
    def name(self):
        return str(self._doc["device"].get("name", ""))

    def owner(self, token):
        """The registration id a token belongs to, or None."""
        if not token:
            return None
        for reg_id, reg in self._regs.items():
            if reg.get("token") and reg["token"] == token:
                return reg_id
        return None

    # -- changing it as the Hue Sync app would (tests, the control API's set) ------------------------

    def _parent(self, path):
        parts = [p for p in str(path).split(".") if p]
        if not parts or parts[0] == "registrations":
            raise ValueError("a dotted path outside registrations, not %r" % (path,))
        node = self._doc
        for part in parts[:-1]:
            if not isinstance(node, dict) or not isinstance(node.get(part), dict):
                raise KeyError(path)
            node = node[part]
        return node, parts[-1]

    def set(self, path, value):
        """Set a dotted path of the document (its parents must exist). hdmi.contentSpecs sets the signal
        a linked input shows (SB78)."""
        node, key = self._parent(path)
        if node is self._doc.get("hdmi") and key == "contentSpecs":
            self._specs = value or None
        node[key] = copy.deepcopy(value)
        self._note("set", "%s set" % path)

    def unset(self, path):
        """Remove a dotted path of the document (a field a model or level lacks)."""
        node, key = self._parent(path)
        if key not in node:
            raise KeyError(path)
        del node[key]
        self._note("set", "%s removed" % path)

    def add_registration(self, reg_id, value, app_name="c4-hue", instance_name="Control4", role="user"):
        """A registration the box knows already: {id: token} or {id: {token, appName, ...}}."""
        if isinstance(value, dict):
            token = value.get("token") or value.get("accessToken")
            entry = {
                "appName": value.get("appName", app_name),
                "instanceName": value.get("instanceName", instance_name),
                "role": value.get("role", role),
            }
        else:
            token, entry = value, {"appName": app_name, "instanceName": instance_name, "role": role}
        if not isinstance(token, str) or not token:
            raise ValueError("registration %s has no token" % reg_id)
        entry["token"] = token
        self._regs[str(reg_id)] = entry
        if str(reg_id).isdigit():
            self._highest = max(self._highest, int(reg_id))

    # -- time ---------------------------------------------------------------------------------------

    def tick(self):
        """What falls due with the clock: the restart ends (SB120), the pairing window closes (SB82)."""
        now = self._now()
        if self._down_until is not None and self._down_until <= now:
            self._down_until = None
            self._note("restart", "the box answers again")
        if self._button_until is not None and self._button_until <= now:
            self._button_until = None
            self._note("button", "the pairing window closed")

    # -- requests -----------------------------------------------------------------------------------

    def request(self, method, path, headers=None, body=None):
        """One request: (status, body), or (None, None) while the box restarts (SB120)."""
        self.tick()
        if self._down_until is not None:
            return None, None
        try:
            return self._answer(str(method).upper(), self.resource(path), headers, body)
        except BoxError as error:
            return error.status, dict(error.body)

    def _error(self, name):
        status, code, message = self._errors[name]
        return BoxError(status, code, message)

    @staticmethod
    def resource(path):
        """The path after /api/v1 ("" for /api/v1); None off the API. The query is ignored."""
        path = str(path or "").split("?", 1)[0]
        if path.startswith("/api/v1"):
            rest = path[len("/api/v1") :]
            if rest and not rest.startswith("/"):
                return None
            return rest.rstrip("/")
        if path.startswith("/api") or (path and not path.startswith("/")):
            return None
        return path.rstrip("/")

    def _answer(self, method, resource, headers, body):
        """SB12, SB13: a token the box does not know is refused (2) on every path; without one only GET
        /device and POST /registrations are served. SB88: a known token's registration is used now.
        SB15: a method a path does not take is 10."""
        if resource is None:
            raise self._error("not_found")
        keyed, token = bearer(headers)
        reg_id = self.owner(token)
        if keyed and reg_id is None:
            raise self._error("unauthorized")
        if reg_id is not None:
            self._regs[reg_id]["lastUsed"] = self._stamp()
        if method == "GET" and resource == "/device" and not keyed:
            return 200, self._unkeyed_device()
        if method == "POST" and resource == "/registrations":
            return self._register(body)
        if reg_id is None:
            raise self._error("unauthorized")
        segments = [s for s in resource.split("/") if s]
        if method == "GET":
            return self._get(segments)
        if method == "PUT":
            return self._put(segments, body)
        if method == "DELETE" and len(segments) == 2 and segments[0] == "registrations":
            return self._unregister(segments[1], reg_id)
        raise self._error("not_found")

    def _unkeyed_device(self):
        """SB12, SB112: the identifying fields of the device as it is now."""
        if self._device_override is not None:
            return copy.deepcopy(self._device_override)
        device = self._doc["device"]
        return {k: copy.deepcopy(device[k]) for k in UNKEYED_DEVICE_FIELDS if k in device}

    def _get(self, segments):
        """SB1, SB2, SB14: the whole state or an object inside it; a scalar or a missing name is 10."""
        node = self._view()
        for segment in segments:
            if not isinstance(node, dict) or segment not in node:
                raise self._error("not_found")
            node = node[segment]
        if not isinstance(node, dict):
            raise self._error("not_found")
        return 200, node

    def _json_body(self, body):
        """SB16, SB17, SB21: no body at all, an empty object and an empty list are 13 (R1 §2.6: an empty
        PUT is 13; an empty Lua table encodes as [], so the Lua fake reads [] as an empty object too);
        text that is not JSON, or JSON that is neither an object nor an empty list, is 12."""
        if isinstance(body, (bytes, bytearray)):
            body = bytes(body).decode("utf-8", "replace")
        if body is None or (isinstance(body, str) and not body.strip()):
            raise self._error("invalid_key")
        if isinstance(body, str):
            try:
                body = json.loads(body)
            except ValueError:
                raise self._error("invalid_json") from None
        if isinstance(body, list) and not body:
            raise self._error("invalid_key")
        if not isinstance(body, dict):
            raise self._error("invalid_json")
        if not body:
            raise self._error("invalid_key")
        return body

    def _atomic(self, apply):
        """SB20, SB56: a refusal at any point leaves the box exactly as it was."""
        saved = (copy.deepcopy(self._doc), copy.deepcopy(self._regs), self._specs, len(self.history))
        try:
            apply()
        except BoxError:
            self._doc, self._regs, self._specs, n = saved
            del self.history[n:]
            raise
        return 200, {}

    def _put(self, segments, body):
        """SB11, SB15: the paths that take a PUT; everything else is 10 (before the body is read)."""
        doc = self._doc
        if segments == ["execution"]:
            route = self._put_execution
        elif segments == ["behavior"] and isinstance(doc.get("behavior"), dict):
            route = self._put_behavior
        elif len(segments) == 2 and segments[0] == "hdmi" and self._is_port(segments[1]):
            port = segments[1]

            def route(data):
                self._put_port(port, data)

        elif segments == ["device"]:
            route = self._put_device
        elif segments == ["hue"] and isinstance(doc.get("hue"), dict):
            route = self._put_hue
        elif len(segments) == 3 and segments[:2] == ["hue", "groups"] and segments[2] in self._groups():
            group = segments[2]

            def route(data):
                self._put_group(group, data)

        else:
            raise self._error("not_found")
        data = self._json_body(body)
        return self._atomic(lambda: route(data))

    # -- registrations (SB80-SB88) ------------------------------------------------------------------

    def _register(self, body):
        """SB80: appName and instanceName, non-empty text (else 15), checked before the button; SB81:
        16 before the button; SB82: the first valid POST in the window answers {registrationId,
        accessToken} and closes it; SB83: ids never reused; SB84: role user, created and lastUsed from
        the clock, verified false from level 10."""
        data = self._json_body(body)
        for key in data:
            if key not in ("appName", "instanceName"):
                raise self._error("invalid_key")
        for key in ("appName", "instanceName"):
            if not isinstance(data.get(key), str) or not data[key].strip():
                raise self._error("invalid_value")
        if self._button_until is None:
            raise self._error("invalid_state")
        reg_id = str(max(FIRST_REGISTRATION_ID, self._highest + 1))
        self._highest = int(reg_id)
        if self.token_factory is not None:
            token = self.token_factory(reg_id)
        else:
            token = TOKEN if self._issued == 0 else "%s-%s" % (TOKEN, reg_id)
        while self.owner(token) is not None:
            token = "%s-%s" % (token, reg_id)
        self._issued += 1
        now = self._stamp()
        entry = {"appName": data["appName"], "instanceName": data["instanceName"], "role": "user"}
        entry.update(created=now, lastUsed=now)
        if self._level() >= 10:
            entry["verified"] = False
        entry["token"] = token
        self._regs[reg_id] = entry
        self._button_until = None
        self._note("registrations", "registration %s for %s made" % (reg_id, data["appName"]))
        return 200, {"registrationId": reg_id, "accessToken": token}

    def _unregister(self, target, reg_id):
        """SB86: DELETE /registrations/<id> with that registration's own token removes it; another's
        token is 2 and removes nothing; an id the box does not hold is 10."""
        if target not in self._regs:
            raise self._error("not_found")
        if target != reg_id:
            raise self._error("unauthorized")
        del self._regs[target]
        self._note("registrations", "registration %s deleted by its app" % target)
        return 200, {}

    # -- execution (SB30-SB56) ----------------------------------------------------------------------

    def _check(self, rule, value):
        """SB19: a known key's value of the wrong type or range is 15."""
        kind = rule[0]
        if kind == "bool":
            ok = isinstance(value, bool)
        elif kind == "int":
            ok = _is_int(value) and rule[1] <= value <= rule[2]
        elif kind == "enum":
            ok = isinstance(value, str) and value in rule[1]
        elif kind == "input":
            ok = isinstance(value, str) and value in self._inputs()
        elif kind == "area":
            ok = self._area_key(value) is not None
        elif kind == "preset":
            ok = isinstance(value, str) and isinstance(self._presets().get(value), dict)
        else:  # object
            ok = isinstance(value, dict)
        if not ok:
            raise self._error("invalid_value")

    def _check_execution(self, data):
        """SB18, SB19, SB21: every key (13) before any value (15), the mode objects' keys included."""
        for key, value in data.items():
            if key not in EXECUTION_KEYS or (key in HDMI_KEYS and not isinstance(self._doc.get("hdmi"), dict)):
                raise self._error("invalid_key")
            if key in MODE_OBJECT_KEYS and isinstance(value, dict):
                for inner in value:
                    if inner not in MODE_OBJECT_KEYS[key]:
                        raise self._error("invalid_key")
        for key, value in data.items():
            if key == "hueTarget" and self._standalone():
                continue  # SB97: refused by state below
            self._check(EXECUTION_KEYS[key], value)
            if key in MODE_OBJECT_KEYS:
                for inner, inner_value in value.items():
                    self._check(MODE_OBJECT_KEYS[key][inner], inner_value)

    def _put_execution(self, data):
        """PUT /execution. SB55: the fields apply in this order, each under its own rule:
          1 preset (SB49: its stored execution as if sent in the same PUT)
          2 hdmiActive, toggleHdmiActive (SB34-SB36)
          3 hdmiSource, cycleHdmiSource (SB39-SB41)
          4 hueTarget (SB48)
          5 mode, toggleSyncMode, cycleSyncMode (SB30, SB31, SB37, SB38)
          6 syncActive, toggleSyncActive (SB32, SB33, SB36)
          7 video, game, music (SB47)
          8 intensity, cycleIntensity, backgroundLighting, toggleBackgroundLighting (SB44-SB46)
          9 brightness, then incrementBrightness (SB42, SB43)
        SB56: the whole PUT is checked first; a refusal by state (16) is judged on its result: in bridge
        mode a result in a sync mode is 16 unless the link was connected or streaming (SB91).
        SB97: hueTarget on a standalone box is 16."""
        execution = self._doc.get("execution")
        if not isinstance(execution, dict):
            raise self._error("not_found")
        self._check_execution(data)
        preset_id = data.get("preset")
        if preset_id is not None:
            stored = self._presets()[preset_id].get("execution")
            stored = {k: v for k, v in (stored if isinstance(stored, dict) else {}).items() if k != "preset"}
            try:
                self._check_execution(stored)
            except BoxError:
                raise self._error("invalid_value") from None
            data = dict(stored, **{k: v for k, v in data.items() if k != "preset"})
        if self._standalone() and "hueTarget" in data:
            raise self._error("invalid_state")
        was_syncing = self._syncing()
        old_area = self._area_key(execution.get("hueTarget"))
        self._deferred = True  # the bridge side follows the result, once (_settle_stream)
        try:
            link_before = self._apply_execution(data, execution)
        finally:
            self._deferred = False
        # SB91, SB56: judged on the result
        if self._syncing() and not self._standalone() and link_before not in ("connected", "streaming"):
            raise self._error("invalid_state")
        self._settle_stream(was_syncing, old_area)
        if preset_id is not None:
            self._presets()[preset_id]["lastUsed"] = self._stamp()
            self._note("presets", "preset %s run" % preset_id)

    def _apply_execution(self, data, execution):
        """Steps 2 to 9 of _put_execution; the link state a sync of this PUT would start on."""
        # 2. power
        if data.get("hdmiActive") is True:
            self._wake("hdmiActive")
        elif data.get("hdmiActive") is False:
            self._powersave("hdmiActive")
        if data.get("toggleHdmiActive") is True:
            if self._mode() == "powersave":
                self._wake("toggleHdmiActive")
            else:
                self._powersave("toggleHdmiActive")
        # 3. input
        if "hdmiSource" in data:
            self._select(data["hdmiSource"], "hdmiSource")
        if "cycleHdmiSource" in data:
            self._select(self._cycle(self._inputs(), execution.get("hdmiSource"), data["cycleHdmiSource"]), "cycle")
        # 4. area
        if "hueTarget" in data:
            self._set_area(data["hueTarget"])
        # The link a sync would start on: as it is once the area is chosen (SB98 may have cleared
        # invalidgroup), before any stream of this PUT.
        link_before = (self._doc.get("hue") or {}).get("connectionState")
        # 5. mode
        if "mode" in data:
            mode = data["mode"]
            if mode == "powersave":
                self._powersave("mode")
            elif mode == "passthrough":
                self._wake("mode")
                self._stop_sync("mode")
            else:
                self._sync(mode, "mode")
        if "toggleSyncMode" in data:
            wanted = data["toggleSyncMode"]
            if self._syncing() and self._mode() == wanted:
                self._stop_sync("toggleSyncMode")
            else:
                self._sync(wanted, "toggleSyncMode")
        if "cycleSyncMode" in data:
            self._sync(self._cycle(SYNC_CYCLE, self._settings_mode(), data["cycleSyncMode"]), "cycleSyncMode")
        # 6. sync on and off
        if data.get("syncActive") is True and not self._syncing():
            self._sync(self._resume_mode(), "syncActive")
        elif data.get("syncActive") is False:
            self._stop_sync("syncActive")
        if data.get("toggleSyncActive") is True:
            if self._syncing():
                self._stop_sync("toggleSyncActive")
            else:
                self._sync(self._resume_mode(), "toggleSyncActive")
        # 7. the mode objects
        for name in SYNC_MODES:
            if name in data:
                execution.setdefault(name, {}).update(copy.deepcopy(data[name]))
        # 8. the settings of the mode in effect
        mode = self._settings_mode()
        settings = execution.setdefault(mode, {})
        if "intensity" in data:
            settings["intensity"] = data["intensity"]
        if "cycleIntensity" in data:
            settings["intensity"] = self._cycle(INTENSITIES, settings.get("intensity"), data["cycleIntensity"])
        if "backgroundLighting" in data or data.get("toggleBackgroundLighting") is True:
            if mode == "music":
                raise self._error("invalid_value")  # SB46: music has no background lighting
            if "backgroundLighting" in data:
                settings["backgroundLighting"] = data["backgroundLighting"]
            if data.get("toggleBackgroundLighting") is True:
                settings["backgroundLighting"] = not settings.get("backgroundLighting", False)
        # 9. brightness
        if "brightness" in data:
            execution["brightness"] = data["brightness"]
        if "incrementBrightness" in data:
            current = execution["brightness"] if _is_int(execution.get("brightness")) else 100
            execution["brightness"] = max(0, min(200, current + data["incrementBrightness"]))
        return link_before

    def _settle_stream(self, was_syncing, old_area):
        """The bridge side of one PUT, from its result only (SB6, SB48, SB56): a sync started, moved to
        another area or ended. A sync on and off within one PUT never touches the link."""
        if not isinstance(self._doc.get("hue"), dict) or self._standalone():
            return
        if self._syncing():
            group = self._groups().get(old_area)
            new_area = self._area_key(self._doc["execution"].get("hueTarget"))
            if was_syncing and old_area != new_area and isinstance(group, dict):
                group["active"] = False
            self._stream(True)
        elif was_syncing:
            self._stream(False, area=old_area)

    @staticmethod
    def _cycle(values, current, direction):
        """The next or previous of `values` after `current`, wrapping round (SB38, SB41, SB45); from the
        first when `current` is not one of them."""
        values = list(values)
        if current not in values:
            return values[0]
        step = 1 if direction == "next" else -1
        return values[(values.index(current) + step) % len(values)]

    def _mode(self):
        return (self._doc.get("execution") or {}).get("mode")

    def _syncing(self):
        """SB3: syncing exactly when the mode is a sync mode."""
        return self._mode() in SYNC_MODES

    def _resume_mode(self):
        """SB32: the selected input's lastSyncMode; then the box's, then video [assumed]."""
        execution = self._doc["execution"]
        port = (self._doc.get("hdmi") or {}).get(execution.get("hdmiSource")) or {}
        for mode in (port.get("lastSyncMode"), execution.get("lastSyncMode")):
            if mode in SYNC_MODES:
                return mode
        return "video"

    def _settings_mode(self):
        """SB44: the current sync mode, else lastSyncMode (else video)."""
        if self._syncing():
            return self._mode()
        last = self._doc["execution"].get("lastSyncMode")
        return last if last in SYNC_MODES else "video"

    def _standalone(self):
        return (self._doc.get("hue") or {}).get("operatingMode") == "standalone"

    def _link_ok(self):
        """SB91, SB97: a stream can start: standalone, or the link connected or streaming."""
        return self._standalone() or (self._doc.get("hue") or {}).get("connectionState") in ("connected", "streaming")

    def _sync(self, mode, why):
        """SB3-SB6, SB31: syncing in `mode`, waking the box; lastSyncMode (box and input) follow, and in
        bridge mode the link streams to the hueTarget area."""
        execution = self._doc["execution"]
        changed = execution.get("mode") != mode
        execution["mode"] = mode
        execution["syncActive"] = True
        if "hdmiActive" in execution:
            execution["hdmiActive"] = True
        execution["lastSyncMode"] = mode
        port = (self._doc.get("hdmi") or {}).get(execution.get("hdmiSource"))
        if isinstance(port, dict):
            port["lastSyncMode"] = mode
        self._stream(True)
        if changed:
            self._note("execution", "syncing %s (%s)" % (mode, why))

    def _stop_sync(self, why):
        """SB33, SB6: from a sync mode to passthrough; the stream ends."""
        if not self._syncing():
            return
        execution = self._doc["execution"]
        execution["mode"] = "passthrough"
        execution["syncActive"] = False
        if "hdmiActive" in execution:
            execution["hdmiActive"] = True
        self._stream(False)
        self._note("execution", "passthrough (%s)" % why)

    def _powersave(self, why):
        """SB4, SB35: powersave from any mode, ending a sync."""
        if self._mode() == "powersave":
            return
        execution = self._doc["execution"]
        was_syncing = self._syncing()
        execution["mode"] = "powersave"
        execution["syncActive"] = False
        if "hdmiActive" in execution:
            execution["hdmiActive"] = False
        if was_syncing:
            self._stream(False)
        self._note("execution", "powersave (%s)" % why)

    def _wake(self, why):
        """SB34: powersave to passthrough; any other mode is kept."""
        if self._mode() != "powersave":
            return
        execution = self._doc["execution"]
        execution["mode"] = "passthrough"
        execution["syncActive"] = False
        if "hdmiActive" in execution:
            execution["hdmiActive"] = True
        self._note("execution", "passthrough: woken (%s)" % why)

    def _stream(self, on, area=None):
        """SB6: in bridge mode, syncing makes the link streaming and the hueTarget area active; stopping
        while streaming makes it connected and the area (`area`, else hueTarget's) inactive. SB97:
        standalone leaves hue alone. Inside a PUT /execution nothing happens until _settle_stream."""
        hue = self._doc.get("hue")
        if self._deferred or not isinstance(hue, dict) or self._standalone():
            return
        target = area if area is not None else self._area_key(self._doc["execution"].get("hueTarget"))
        groups = self._groups()
        if on:
            hue["connectionState"] = "streaming"
            group = groups.get(target)
            if isinstance(group, dict):
                group["active"] = True
        elif hue.get("connectionState") == "streaming":
            hue["connectionState"] = "connected"
            group = groups.get(target)
            if isinstance(group, dict):
                group["active"] = False
                group.pop("owner", None)

    def _select(self, port, why):
        """SB39: the input changes and the mode is kept: a syncing box goes on in the same mode, which
        becomes the new input's lastSyncMode; a box in powersave stays in it."""
        execution = self._doc["execution"]
        if execution.get("hdmiSource") == port:
            return
        execution["hdmiSource"] = port
        if self._syncing():
            self._doc["hdmi"][port]["lastSyncMode"] = self._mode()
        self._note("execution", "input %s (%s)" % (port, why))

    def _area_key(self, value):
        """SB48: a key of hue.groups, or groups/<n> naming the key <n>; None otherwise."""
        if not isinstance(value, str):
            return None
        groups = self._groups()
        if value in groups:
            return value
        if value.startswith("groups/") and value[len("groups/") :] in groups:
            return value[len("groups/") :]
        return None

    def _set_area(self, value):
        """SB48, SB7: hueTarget and (level 10) groupId change together; while syncing the stream moves
        (the old area inactive, the new one active). SB98: an invalidgroup link becomes connected."""
        execution = self._doc["execution"]
        old = self._area_key(execution.get("hueTarget"))
        execution["hueTarget"] = value
        hue = self._doc.get("hue")
        if isinstance(hue, dict) and "groupId" in hue:
            hue["groupId"] = value
        if isinstance(hue, dict) and hue.get("connectionState") == "invalidgroup":
            hue["connectionState"] = "connected"  # SB98
        if self._syncing() and not self._standalone() and not self._deferred:
            group = self._groups().get(old)
            if isinstance(group, dict) and old != self._area_key(value):
                group["active"] = False
            self._stream(True)

    # -- behavior (SB60-SB64) -----------------------------------------------------------------------

    def _put_behavior(self, data):
        """SB60-SB62: box-wide numbers and input<n> objects, each key one this model and level has (13
        otherwise, every key before any value); flags 0 or 1 (true/false are 15), inactivePowersave
        0-10000, hdrMode 0-2. SB63: nothing happens until the next event."""
        behavior = self._doc["behavior"]
        for key, value in data.items():
            if key not in behavior:
                raise self._error("invalid_key")
            if isinstance(behavior[key], dict) and isinstance(value, dict):
                for inner in value:
                    if inner not in behavior[key] or isinstance(behavior[key][inner], dict):
                        raise self._error("invalid_key")
        for key, value in data.items():
            if isinstance(behavior[key], dict):
                if not isinstance(value, dict) or not value:
                    raise self._error("invalid_value")
                for inner, inner_value in value.items():
                    self._check_behavior(inner, inner_value)
            else:
                self._check_behavior(key, value)
        for key, value in data.items():
            if isinstance(behavior[key], dict):
                behavior[key].update(value)
            else:
                behavior[key] = value
        self._note("behavior", "behavior changed: %s" % ", ".join(sorted(data)))

    def _check_behavior(self, key, value):
        low, high = BEHAVIOR_RANGES.get(key, (0, 1))
        if not _is_int(value) or not low <= value <= high:
            raise self._error("invalid_value")

    # -- hdmi (SB100), device (SB110, SB111), hue (SB94-SB97) ---------------------------------------

    def _put_port(self, port, data):
        """SB100: PUT /hdmi/<port> takes name (non-empty text) and type (one of the 26); status and
        lastSyncMode, or any other key, are 13."""
        for key in data:
            if key not in ("name", "type"):
                raise self._error("invalid_key")
        if "name" in data and not (isinstance(data["name"], str) and data["name"].strip()):
            raise self._error("invalid_value")
        if "type" in data and data["type"] not in PORT_TYPES:
            raise self._error("invalid_value")
        self._doc["hdmi"][port].update(data)
        self._note("hdmi", "%s changed: %s" % (port, ", ".join(sorted(data))))

    def _put_device(self, data):
        """SB110: name (non-empty text) and ledMode (0, 1, 2); SB111: every other key is 13 (action,
        update and bluetooth included: the fakes leave them out)."""
        for key in data:
            if key not in ("name", "ledMode"):
                raise self._error("invalid_key")
        if "name" in data and not (isinstance(data["name"], str) and data["name"].strip()):
            raise self._error("invalid_value")
        if "ledMode" in data and not (_is_int(data["ledMode"]) and 0 <= data["ledMode"] <= 2):
            raise self._error("invalid_value")
        self._doc["device"].update(data)
        self._note("device", "changed through the API: %s" % ", ".join(sorted(data)))

    def _put_hue(self, data):
        """SB95: groupId (from level 10) selects an area as hueTarget does; SB96: a bridge change
        (bridgeUniqueId, username, clientKey) and every other key are 13; SB97: standalone is 16."""
        hue = self._doc["hue"]
        for key in data:
            if key != "groupId" or "groupId" not in hue:
                raise self._error("invalid_key")
        if self._standalone():
            raise self._error("invalid_state")
        self._check(("area",), data["groupId"])
        self._set_area(data["groupId"])

    def _put_group(self, group_id, data):
        """SB94: {"active": false} stops whoever streams to that area: this box goes to passthrough and
        connected; another app's stream (busy) ends, the area inactive without an owner and the link
        connected; an inactive area stays so. {"active": true} is 15."""
        for key in data:
            if key != "active":
                raise self._error("invalid_key")
        if data["active"] is not False:
            raise self._error("invalid_value")
        hue = self._doc["hue"]
        group = self._groups()[group_id]
        if not isinstance(group, dict) or not group.get("active"):
            return
        if self._syncing() and self._area_key(self._doc["execution"].get("hueTarget")) == group_id:
            self._stop_sync("its area's stream stopped")
        elif hue.get("connectionState") == "busy":
            group["active"] = False
            group.pop("owner", None)
            hue["connectionState"] = "connected"
            self._note("hue", "the other app's stream stopped")

    # -- events -------------------------------------------------------------------------------------

    def event(self, name, /, **args):
        """One event of the house (module docstring); ValueError for an unknown event or argument."""
        handler = getattr(self, "_ev_" + str(name), None)
        if handler is None:
            raise ValueError("no event %r (have %s)" % (name, ", ".join(EVENTS)))
        self.tick()
        try:
            handler(**args)
        except TypeError as error:
            raise ValueError("event %s: %s" % (name, error)) from None
        self.tick()

    def _ev_advance(self, ms):
        """§12: the clock moves on; what falls due runs."""
        self.clock.advance(ms)

    def _ev_button(self, window=None):
        """SB82: the button held about 3 s opens a 5 s window (or `window` s) for one registration.
        Ignored while the box restarts."""
        if self._down_until is not None:
            return
        length = self.pairing_window_ms if window is None else float(window) * 1000.0
        self._button_until = self._now() + length
        self._note("button", "button held: pairing open")

    def _both_linked(self):
        """SB73: the selected input and the output both read linked (SB72's masking)."""
        port = (self._doc.get("execution") or {}).get("hdmiSource")
        return self._read_status(port) == "linked" and self._read_status("output") == "linked"

    def _snapshot(self):
        return (self._doc["execution"].get("hdmiSource"), self._both_linked())

    def _autosync(self, before):
        """SB73: after an event that makes the selected input and the output both read linked when they
        did not for that input before, a box in passthrough whose input has linkAutoSync 1 syncs in the
        input's lastSyncMode (when the link can carry a stream [assumed])."""
        port = self._doc["execution"].get("hdmiSource")
        if not self._both_linked() or before == (port, True):
            return
        flags = (self._doc.get("behavior") or {}).get(port) or {}
        if self._mode() == "passthrough" and flags.get("linkAutoSync") == 1:
            if self._link_ok():
                self._sync(self._resume_mode(), "linkAutoSync")
            else:
                self._note("linkAutoSync", "no sync: the bridge link cannot take a stream")

    def _switch(self, port, why):
        """SB70, SB71: select the input, keeping the mode (SB39), waking from powersave."""
        self._wake(why)
        self._select(port, why)

    def _ev_cec_active_source(self, input):
        """SB70: with that input's cecInputSwitch 1 the box selects it and wakes; else nothing."""
        port = _port_name(input)
        if port not in self._inputs():
            return
        before = self._snapshot()
        if ((self._doc.get("behavior") or {}).get(port) or {}).get("cecInputSwitch") == 1:
            self._switch(port, "CEC Active Source")
            self._autosync(before)
        else:
            self._note("cec", "CEC Active Source on %s: cecInputSwitch 0" % port)

    def _ev_hotplug(self, input):
        """SB71: the input reads at least plugged; with hpdInputSwitch (HSB1, HSB2) or the input's
        hpdInputPortSwitch (level 10) at 1 the box selects it as in SB70."""
        port = _port_name(input)
        if port not in self._inputs():
            return
        before = self._snapshot()
        hdmi_port = self._doc["hdmi"][port]
        if hdmi_port.get("status") not in ("plugged", "linked"):
            hdmi_port["status"] = "plugged"
        behavior = self._doc.get("behavior") or {}
        if behavior.get("hpdInputSwitch") == 1 or (behavior.get(port) or {}).get("hpdInputPortSwitch") == 1:
            self._switch(port, "hot-plug")
        else:
            self._note("hpd", "hot-plug on %s: no switch" % port)
        self._autosync(before)

    def _ev_signal(self, input, status):
        """SB72: the port's status; SB74: the selected input no longer linked ends a sync; SB73."""
        port = _port_name(input)
        if status not in PORT_STATUSES:
            raise ValueError("a status is one of %s" % ", ".join(PORT_STATUSES))
        if not self._is_port(port):
            return
        before = self._snapshot()
        self._doc["hdmi"][port]["status"] = status
        if port == self._doc["execution"].get("hdmiSource") and status != "linked" and self._syncing():
            self._stop_sync("the source's link went")
        self._autosync(before)

    def _ev_tv_standby(self):
        """SB75: with cecPowersave 1, powersave."""
        if (self._doc.get("behavior") or {}).get("cecPowersave") == 1:
            self._powersave("the TV's CEC standby")

    def _ev_usb_power_lost(self):
        """SB76: with usbPowersave 1 (HSB1, HSB2), powersave."""
        if (self._doc.get("behavior") or {}).get("usbPowersave") == 1:
            self._powersave("the TV's USB power")

    def _ev_idle(self, minutes):
        """SB77: in passthrough, with inactivePowersave above 0 and at most `minutes`, and no input
        reading linked or the output not reading linked: powersave. No idle timer (§12)."""
        limit = (self._doc.get("behavior") or {}).get("inactivePowersave")
        if self._mode() != "passthrough" or not _is_int(limit) or limit <= 0 or limit > float(minutes):
            return
        any_linked = any(self._read_status(port) == "linked" for port in self._inputs())
        if not any_linked or self._read_status("output") != "linked":
            self._powersave("inactivePowersave after %s idle minutes" % minutes)

    def _ev_bridge(self, state):
        """SB90: hue.connectionState. SB92: busy is another app streaming to the hueTarget area (active,
        owner other-app). SB93: any state but connected ends a sync, and every state but busy leaves all
        areas inactive; connected clears another app's stream and leaves a syncing box streaming."""
        if state not in CONNECTION_STATES and state != "streaming":
            raise ValueError("a state is one of %s" % ", ".join(CONNECTION_STATES))
        hue = self._doc.get("hue")
        if not isinstance(hue, dict):
            raise ValueError("this box has no hue resource")
        groups = self._groups()
        if state in ("connected", "streaming"):
            for group in groups.values():
                if isinstance(group, dict) and group.get("owner") is not None:
                    group["active"] = False
                    group.pop("owner", None)
            hue["connectionState"] = "streaming" if self._syncing() and not self._standalone() else "connected"
        else:
            self._stop_sync("bridge %s" % state)
            hue["connectionState"] = state
            for group in groups.values():
                if isinstance(group, dict):
                    group["active"] = False
                    group.pop("owner", None)
            if state == "busy":
                group = groups.get(self._area_key(self._doc["execution"].get("hueTarget")))
                if isinstance(group, dict):
                    group["active"] = True
                    group["owner"] = OTHER_APP
        self._note("hue", "bridge %s" % state)

    def _ev_rename(self, name):
        """SB112: device.name; the unkeyed GET /device shows it too."""
        self._doc["device"]["name"] = str(name)
        self._note("device", "renamed in the app")

    def _ev_app_deletes(self, registration):
        """SB87: the registration is gone and its token is refused (2)."""
        reg_id = str(registration)
        if reg_id not in self._regs:
            raise ValueError("no registration %s" % reg_id)
        del self._regs[reg_id]
        self._note("registrations", "registration %s deleted in the app" % reg_id)

    def _ev_firmware(self, version, api_level=None):
        """SB121: the box restarts (SB120) and then reports the version, the level and a buildNumber made
        from the version; SB122: a level reaching 10 or 14 adds the fields the state lacks."""
        device = self._doc["device"]
        old = device.get("apiLevel") if _is_int(device.get("apiLevel")) else 0
        device["firmwareVersion"] = str(version)
        device["buildNumber"] = build_number(version)
        if api_level is not None:
            device["apiLevel"] = int(api_level)
            self._upgrade(old, int(api_level))
        self._note("device", "firmware %s installed" % version)
        self._restart("firmware update")

    def _upgrade(self, old, new):
        """SB122: level 10 adds hue.groupId (= hueTarget), each input's hpdInputPortSwitch 0,
        device.overheating false, device.bluetooth true and verified false on each registration; level
        14 adds behavior.soloMode 0 and, on HSB2 and HSB3, hue.operatingMode bridge."""
        device, hue, behavior = self._doc["device"], self._doc.get("hue"), self._doc.get("behavior")
        if old < 10 <= new:
            if isinstance(hue, dict):
                hue.setdefault("groupId", self._doc["execution"].get("hueTarget", ""))
            if isinstance(behavior, dict):
                for key, flags in behavior.items():
                    if re.fullmatch(r"input\d+", key) and isinstance(flags, dict):
                        flags.setdefault("hpdInputPortSwitch", 0)
            device.setdefault("overheating", False)
            device.setdefault("bluetooth", True)
            for reg in self._regs.values():
                reg.setdefault("verified", False)
        if old < 14 <= new:
            if isinstance(behavior, dict):
                behavior.setdefault("soloMode", 0)
            if isinstance(hue, dict) and self.model in ("HSB2", "HSB3"):
                hue.setdefault("operatingMode", "bridge")

    def _ev_reboot(self):
        """SB120: 30 s of the box's clock without an answer, then the same state, the window closed."""
        self._restart("reboot")

    def _restart(self, why):
        self._down_until = self._now() + self.reboot_ms
        self._button_until = None
        self._note("restart", "restarting (%s)" % why)

    def _ev_address(self, address, port=None):
        """SB114: device.ipAddress, nothing else (the server moves to `port` when given)."""
        del port  # the server's part
        self._doc["device"]["ipAddress"] = str(address)
        self._note("device", "address changed")

    def _ev_operating_mode(self, mode):
        """R1 §1.5 (level 14): bridge or standalone; a sync ends with the change."""
        if mode not in OPERATING_MODES:
            raise ValueError("a mode is one of %s" % ", ".join(OPERATING_MODES))
        hue = self._doc.get("hue")
        if not isinstance(hue, dict) or "operatingMode" not in hue:
            raise ValueError("this box has no hue.operatingMode")
        self._stop_sync("operating mode %s" % mode)
        hue["operatingMode"] = mode
        self._note("hue", "operating mode %s" % mode)

    # -- helpers ------------------------------------------------------------------------------------

    def _level(self):
        level = self._doc["device"].get("apiLevel")
        return level if _is_int(level) else 0

    def _groups(self):
        groups = (self._doc.get("hue") or {}).get("groups")
        return groups if isinstance(groups, dict) else {}

    def _presets(self):
        presets = self._doc.get("presets")
        return presets if isinstance(presets, dict) else {}

    def _inputs(self):
        hdmi = self._doc.get("hdmi") or {}
        names = [k for k in hdmi if re.fullmatch(r"input\d+", k) and isinstance(hdmi[k], dict)]
        return sorted(names, key=lambda k: int(k[5:]))

    def _ports(self):
        hdmi = self._doc.get("hdmi") or {}
        return self._inputs() + (["output"] if isinstance(hdmi.get("output"), dict) else [])

    def _is_port(self, name):
        return name in self._ports()

    def _note(self, kind, text):
        self.history.append({"ms": int(round(self._now())), "kind": kind, "text": text})
        if len(self.history) > HISTORY_MAX:
            del self.history[: len(self.history) - HISTORY_MAX]


EVENTS = tuple(sorted(name[4:] for name in dir(Box) if name.startswith("_ev_")))
