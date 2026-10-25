#!/usr/bin/env python3
"""smart_scene_probe.py: do time-based scenes made through the API run their slot changes? (issue #40)

Hue's time-based scenes are CLIP v2 `smart_scene` resources: a weekly list of time slots, each
naming an ordinary scene. An app-made one on the house bridge advanced at its 16:00 slot, a
throwaway one made through the API did not (docs/smart-scenes-research.md §7, "Slot advance").
This script makes a small, dim, short-lived schedule to tell whether API-made ones advance at
all, watches it, and removes it again (the test plan is §8 of that document).

Every request reaches the bridge through the dev loop (docs/dev-loop.md), never directly: the
script queues `Hue Request` actions with tools/devctl.py (Raw=true) and reads the answers from
<state-dir>/driver.log, where a dev build of the bridge driver logs each one as
"Hue Request <METHOD> <path> via <host>: HTTP <code> in <n> s, <bytes> bytes: <summary>" and
then the whole body in "Hue Request body <i>/<n>: <800 characters>" pieces. So a dev build must
be installed and tools/devserver.py running; nothing here talks to the bridge or the controller.

  create --room <rid> [--minutes 3] [--brightness 1] [--days today|all] [--light <rid>]...
      Two throwaway scenes of that room (or --zone), every light at the brightness in warm white
      (A 2200 K, B 2700 K: a slot change also shows in the lights' mirek), and the smart scene
      "c4-hue probe": slot A from the current minute, slot B --minutes later, on today's weekday
      (and tomorrow's when B passes midnight; --days all: every weekday, as the Hue app's own
      schedules are). The bridge starts a new smart scene at once (research §7, V12), so the
      lights take scene A now. The ids go to <state-dir>/smart_scene_probe.json, saved after
      every step, so cleanup finds whatever was made.
  activate
      PUT {"recall": {"action": "activate"}} on the probe, as the bridge driver's ON does; then GET it.
  watch [--until HH:MM] [--interval 20]
      GET the probe, its two scenes and its first light every 20 s until --until (default: 3
      minutes after slot B), print state, active_timeslot, the scenes' status and the light with
      the controller's timestamps, then whether slot B started. --smart <rid> [--light <rid>]
      watches any smart scene instead, an app-made one across its slot boundary for example
      (--until needed then).
  cleanup [--keep-lights]
      Deactivate the probe, delete the smart scene and both scenes, GET each to confirm HTTP 404,
      turn the probe lights off again (those that were off before and still show about the probe's
      level), and remove the state file; whatever is left stays in it for the next cleanup.
  run --room <rid> [create options] [--interval 20]
      create, activate, watch, cleanup; the cleanup also runs after an error or Ctrl-C.

Safety in a lived-in house: a brightness above 5 % is refused without --allow-bright; create
refuses while a probe light is on (someone may be using the room) without --allow-on; lights that
cannot dim (plugs) are left out of the scenes; one probe at a time. Slot times are this machine's
local time: create prints the bridge's time zone beside it. Exit codes: 0 done, 1 error, 2 usage,
130 interrupted. Standard library only.
"""

import argparse
import dataclasses
import datetime
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STATE_DIR = os.path.join(ROOT, "build", "dev")
STATE_NAME = "smart_scene_probe.json"
STATE_SCHEMA = 1

RESOURCE = "/clip/v2/resource"
PROBE_NAME = "c4-hue probe"
SCENE_NAME = {"a": "c4-hue probe A", "b": "c4-hue probe B"}
# Both scenes are warm white at the same brightness; B is a little cooler, so a
# slot change shows in a light's mirek as well as in active_timeslot.
SCENE_MIREK = {"a": 454, "b": 370}
SCENE_KELVIN = {"a": 2200, "b": 2700}

DEFAULT_BRIGHTNESS = 1.0
SAFE_BRIGHTNESS = 5.0
DEFAULT_MINUTES = 3
MIN_MINUTES, MAX_MINUTES = 2, 120
# What every app-made schedule on the house bridge carries (research §7, V1);
# the API-made one that did not advance had 5000.
DEFAULT_TRANSITION_MS = 60000
MAX_TRANSITION_MS = 3600000
# Slot A starts in the minute this long ago, so it has begun on the bridge's
# clock as well (a few seconds of drift either way change nothing).
START_MARGIN_S = 15
AFTER_B_MINUTES = 3
DEFAULT_INTERVAL_S = 20.0
MIN_INTERVAL_S = 5.0
DEFAULT_TIMEOUT_S = 45.0
MAX_WATCH_HOURS = 4
MAX_POLL_FAILURES = 3
# cleanup leaves a light on whose brightness rose more than this above the
# probe's: somebody took it over.
CHANGED_ABOVE = 2.0

# date.weekday() order, and the order of the Hue app's recurrence lists.
WEEKDAYS = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
APP_WEEK = ("sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday")


class ProbeError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


def say(text):
    print(text, flush=True)


def resource_path(rtype, rid=None):
    return "%s/%s/%s" % (RESOURCE, rtype, rid) if rid else "%s/%s" % (RESOURCE, rtype)


def short(rid):
    return str(rid)[:8] if rid else "?"


def table(value):
    return value if isinstance(value, dict) else {}


# ---------------------------------------------------------------------------
# Checks and request bodies (no I/O)
# ---------------------------------------------------------------------------


def check_brightness(value, allow_bright=False):
    """The brightness for the scenes, a number in (0, 100]; above SAFE_BRIGHTNESS only with
    allow_bright. A whole number comes back as an int, so the bodies read 1, not 1.0."""
    try:
        value = float(value)
    except (TypeError, ValueError):
        raise ProbeError("brightness %r is not a number" % (value,)) from None
    if not 0 < value <= 100:
        raise ProbeError("brightness %g is outside 0 < brightness <= 100" % value)
    if value > SAFE_BRIGHTNESS and not allow_bright:
        raise ProbeError(
            "brightness %g %% is above %g %%: people live here; pass --allow-bright if you mean it"
            % (value, SAFE_BRIGHTNESS)
        )
    return int(value) if value.is_integer() else round(value, 2)


def check_timing(minutes, transition_ms):
    if isinstance(minutes, bool) or not isinstance(minutes, int) or not MIN_MINUTES <= minutes <= MAX_MINUTES:
        raise ProbeError("--minutes %r is outside %d to %d" % (minutes, MIN_MINUTES, MAX_MINUTES))
    if isinstance(transition_ms, bool) or not isinstance(transition_ms, int):
        raise ProbeError("--transition-ms %r is not a whole number" % (transition_ms,))
    if not 0 <= transition_ms <= MAX_TRANSITION_MS:
        raise ProbeError("--transition-ms %d is outside 0 to %d" % (transition_ms, MAX_TRANSITION_MS))
    if transition_ms >= minutes * 60000:
        raise ProbeError("--transition-ms %d is not shorter than slot A (%d min)" % (transition_ms, minutes))


def weekday_name(moment):
    return WEEKDAYS[moment.weekday()]


def slot_times(now, minutes):
    """Slot A's and slot B's start (seconds 0): A in the minute START_MARGIN_S before `now`, B
    `minutes` after A."""
    a = (now - datetime.timedelta(seconds=START_MARGIN_S)).replace(second=0, microsecond=0)
    return a, a + datetime.timedelta(minutes=minutes)


def recurrence(a, b, days="today"):
    """The weekdays of the one week entry: every day for "all" (the app's order), else A's day
    and, when B passes midnight, B's day as well."""
    if days == "all":
        return list(APP_WEEK)
    names = [weekday_name(a)]
    if weekday_name(b) != names[0]:
        names.append(weekday_name(b))
    return names


def start_time(moment):
    return {"kind": "time", "time": {"hour": moment.hour, "minute": moment.minute, "second": 0}}


def hhmm(moment):
    return "%02d:%02d" % (moment.hour, moment.minute)


def light_info(item):
    """What the probe needs of a light resource."""
    item = table(item)
    ct = item.get("color_temperature")
    schema = table(table(ct).get("mirek_schema"))
    return {
        "rid": item.get("id"),
        "name": str(table(item.get("metadata")).get("name") or item.get("id")),
        "on": table(item.get("on")).get("on") is True,
        "dims": isinstance(item.get("dimming"), dict),
        "ct": isinstance(ct, dict),
        "mirek_min": schema.get("mirek_minimum"),
        "mirek_max": schema.get("mirek_maximum"),
    }


def member_lights(group, lights, only=()):
    """The group's lights the probe's scenes take (they can dim) and those left out.

    A room's children are devices, so its lights are the ones a child device owns; a zone's
    children are the lights themselves. `only` (light rids) narrows it to some of them."""
    group = table(group)
    children = [table(child) for child in group.get("children") or []]
    lights = [item for item in lights or [] if isinstance(item, dict)]
    if group.get("type") == "zone":
        ids = {child.get("rid") for child in children if child.get("rtype") == "light"}
        members = [item for item in lights if item.get("id") in ids]
    else:
        owners = {child.get("rid") for child in children if child.get("rtype") == "device"}
        members = [item for item in lights if table(item.get("owner")).get("rid") in owners]
    infos = [light_info(item) for item in members]
    if only:
        known = {info["rid"] for info in infos}
        unknown = [rid for rid in only if rid not in known]
        if unknown:
            raise ProbeError("not a light of this %s: %s" % (group.get("type") or "group", ", ".join(unknown)))
        infos = [info for info in infos if info["rid"] in only]
    return [info for info in infos if info["dims"]], [info for info in infos if not info["dims"]]


def scene_mirek(light, wanted):
    """`wanted` within the light's mirek range, or None for a light without colour temperature."""
    if not light.get("ct"):
        return None
    low, high = light.get("mirek_min"), light.get("mirek_max")
    if isinstance(low, (int, float)) and wanted < low:
        return int(low)
    if isinstance(high, (int, float)) and wanted > high:
        return int(high)
    return wanted


def scene_action(light, brightness, mirek):
    action = {"on": {"on": True}, "dimming": {"brightness": brightness}}
    value = scene_mirek(light, mirek)
    if value is not None:
        action["color_temperature"] = {"mirek": value}
    return {"target": {"rid": light["rid"], "rtype": "light"}, "action": action}


def scene_body(name, group_rid, group_type, lights, brightness, mirek):
    """POST /scene, in the shape the house bridge accepted on 2026-10-24 (research §7, V12)."""
    if not lights:
        raise ProbeError("no light that can dim: nothing to put in scene %r" % name)
    return {
        "metadata": {"name": name},
        "group": {"rid": group_rid, "rtype": group_type},
        "actions": [scene_action(light, brightness, mirek) for light in lights],
    }


def smart_scene_body(name, group_rid, group_type, scene_a, scene_b, a, b, days="today", transition_ms=None):
    """POST /smart_scene, the shape V12 accepted: one week entry holding slot A then slot B. A slot
    after midnight comes last, as in the app's schedules, whose 00:00 slot follows 22:00."""
    return {
        "metadata": {"name": name},
        "group": {"rid": group_rid, "rtype": group_type},
        "week_timeslots": [
            {
                "timeslots": [
                    {"start_time": start_time(a), "target": {"rid": scene_a, "rtype": "scene"}},
                    {"start_time": start_time(b), "target": {"rid": scene_b, "rtype": "scene"}},
                ],
                "recurrence": recurrence(a, b, days),
            }
        ],
        "transition_duration": DEFAULT_TRANSITION_MS if transition_ms is None else transition_ms,
    }


def slot_start_text(start):
    start = table(start)
    clock = table(start.get("time"))
    hour, minute = clock.get("hour"), clock.get("minute")
    if start.get("kind") == "time" and isinstance(hour, int) and isinstance(minute, int):
        return "%02d:%02d" % (hour, minute)
    return str(start.get("kind") or "?")


def active_slot(item):
    """(index, weekday, start, target rid) of the slot `active_timeslot` names: its timeslot_id
    indexes the timeslots of the week entry whose recurrence holds its weekday (research §7, V3).
    None when the item names no slot, or one it does not have."""
    item = table(item)
    active = table(item.get("active_timeslot"))
    weekday, index = active.get("weekday"), active.get("timeslot_id")
    if weekday is None or isinstance(index, bool) or not isinstance(index, int):
        return None
    for week in item.get("week_timeslots") or []:
        week = table(week)
        if weekday not in (week.get("recurrence") or []):
            continue
        slots = week.get("timeslots") or []
        if 0 <= index < len(slots):
            slot = table(slots[index])
            return index, weekday, slot_start_text(slot.get("start_time")), table(slot.get("target")).get("rid")
    return None


def until_time(text, now):
    """The next HH:MM after `now` (local time), at most MAX_WATCH_HOURS away."""
    match = re.fullmatch(r"\s*(\d{1,2}):(\d{2})\s*", text or "")
    if not match or int(match.group(1)) > 23 or int(match.group(2)) > 59:
        raise ProbeError("--until wants HH:MM, not %r" % (text,))
    end = now.replace(hour=int(match.group(1)), minute=int(match.group(2)), second=0, microsecond=0)
    if end <= now:
        end += datetime.timedelta(days=1)
    if end - now > datetime.timedelta(hours=MAX_WATCH_HOURS):
        raise ProbeError(
            "--until %s is %s away; a watch lasts at most %d h" % (text.strip(), str(end - now)[:-3], MAX_WATCH_HOURS)
        )
    return end


# ---------------------------------------------------------------------------
# The probe's state file
# ---------------------------------------------------------------------------


def save_state(path, state):
    """Write the state atomically (a crash leaves the old file or the new one, never half)."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def load_state(path):
    """The saved state, or None when there is no state file."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise ProbeError("unreadable state file %s (%s)" % (path, exc)) from exc
    if not isinstance(state, dict) or state.get("schema") != STATE_SCHEMA:
        raise ProbeError("%s is not a smart_scene_probe state file" % path)
    return state


# ---------------------------------------------------------------------------
# Answers in the shipped driver log
# ---------------------------------------------------------------------------

STAMP = re.compile(r"\d{2}:\d{2}:\d{2}\.\d{3} ")
SUMMARY = re.compile(
    r"Hue Request (?P<method>[A-Z]+) (?P<path>\S+) via \S+: (?P<status>.*?) in -?\d+ s, (?P<bytes>\d+) bytes: "
)
PIECE = re.compile(r"Hue Request body (?P<i>\d+)/(?P<n>\d+): (?P<text>.*)")
REFUSAL = re.compile(r"Hue Request: (?P<why>.*)")


@dataclasses.dataclass
class Answer:
    """One Hue Request as the bridge driver logged it: the summary line and the body's pieces."""

    method: str
    path: str
    status: str
    nbytes: int
    stamp: str
    pieces: list = dataclasses.field(default_factory=list)
    total: int | None = None

    @property
    def code(self):
        match = re.fullmatch(r"HTTP (\d+)", self.status.strip())
        return int(match.group(1)) if match else None

    @property
    def ok(self):
        return self.code is not None and 200 <= self.code < 300

    @property
    def complete(self):
        return self.nbytes == 0 or (self.total is not None and len(self.pieces) == self.total)

    @property
    def body(self):
        return "".join(self.pieces)

    @property
    def doc(self):
        try:
            return json.loads(self.body)
        except ValueError:
            return None

    def data(self):
        doc = self.doc
        return doc["data"] if isinstance(doc, dict) and isinstance(doc.get("data"), list) else []

    def errors(self):
        doc = self.doc
        if not isinstance(doc, dict) or not isinstance(doc.get("errors"), list):
            return []
        return [str(table(error).get("description", error)) for error in doc["errors"]]

    def problem(self):
        errors = self.errors()
        return self.status + (": " + "; ".join(errors) if errors else "")

    def item(self):
        """The first resource of the answer's data, or {}."""
        data = self.data()
        return table(data[0]) if data else {}


@dataclasses.dataclass
class Parsed:
    answers: dict
    refusals: list


def parse_answers(text, wanted):
    """The answers to the (METHOD, path) pairs in `wanted` found in shipped log text.

    A summary line starts an answer (the first one per pair counts); the pieces follow it, in
    order and contiguous, since the driver logs them from one callback. A body holding a newline
    (Hue ends PUT, POST and DELETE answers with one) continues on lines without a timestamp,
    which belong to the line before. The last line counts only once it has its newline. Lines
    "Hue Request: <why>" (not paired, identity not verified, Host refused, Body not JSON) are
    returned as refusals."""
    wanted = set(wanted)
    answers, refusals = {}, []
    collecting = None  # the answer whose pieces are due
    tail = None  # the answer whose last piece the previous line was
    for line in text.split("\n")[:-1]:
        stamp = STAMP.match(line)
        if not stamp:
            if tail is not None:
                tail.pieces[-1] += "\n" + line
            continue
        tail = None
        rest = line[stamp.end() :]
        summary = SUMMARY.search(rest)
        if summary:
            collecting = None
            key = (summary.group("method"), summary.group("path"))
            if key in wanted and key not in answers:
                answer = Answer(
                    method=key[0],
                    path=key[1],
                    status=summary.group("status"),
                    nbytes=int(summary.group("bytes")),
                    stamp=line[: stamp.end() - 1],
                )
                answers[key] = answer
                if answer.nbytes > 0:
                    collecting = answer
            continue
        piece = PIECE.search(rest)
        if piece:
            index, total = int(piece.group("i")), int(piece.group("n"))
            if collecting is not None and index == len(collecting.pieces) + 1 and collecting.total in (None, total):
                collecting.total = total
                collecting.pieces.append(piece.group("text"))
                tail = collecting
                if index == total:
                    collecting = None
            continue
        refusal = REFUSAL.search(rest)
        if refusal:
            refusals.append(refusal.group("why").strip())
    return Parsed(answers, refusals)


# ---------------------------------------------------------------------------
# The dev loop: tools/devctl.py and the shipped log
# ---------------------------------------------------------------------------


class DevLoop:
    """Hue Requests through the dev loop. `devctl(args)` returns (exit code, stdout, stderr)
    of tools/devctl.py; the default runs it as a subprocess."""

    def __init__(
        self,
        state_dir=DEFAULT_STATE_DIR,
        timeout=DEFAULT_TIMEOUT_S,
        devctl=None,
        sleep=time.sleep,
        clock=time.monotonic,
    ):
        self.state_dir = state_dir
        self.log_path = os.path.join(state_dir, "driver.log")
        self.timeout = timeout
        self.devctl = devctl or self.run_devctl
        self.sleep = sleep
        self.clock = clock

    def run_devctl(self, args):
        argv = [sys.executable, "-I", os.path.join(ROOT, "tools", "devctl.py"), "--state-dir", self.state_dir, *args]
        done = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, check=False)
        return done.returncode, done.stdout, done.stderr

    def log_size(self):
        try:
            return os.path.getsize(self.log_path)
        except OSError:
            return 0

    def read_from(self, offset):
        try:
            with open(self.log_path, "rb") as f:
                if f.seek(0, os.SEEK_END) < offset:
                    offset = 0  # replaced or truncated: all of it is new
                f.seek(offset)
                return f.read().decode("utf-8", "replace")
        except OSError:
            return ""

    def requests(self, batch):
        """Run (method, path, body or None) requests in one dev-loop tick; their answers in order.
        One request per method and path in a batch: the log names answers by both."""
        keys = [(method.upper(), path) for method, path, _ in batch]
        if len(set(keys)) != len(keys):
            raise ProbeError("one batch takes one request per method and path: %s" % keys)
        if not batch:
            return []
        offset = self.log_size()
        last = None
        for method, path, body in batch:
            args = ["run", "Hue Request", "Method=" + method.upper(), "Path=" + path, "Raw=true"]
            if body is not None:
                args.append("Body=" + json.dumps(body, separators=(",", ":")))
            code, out, err = self.devctl(args)
            if code != 0:
                raise ProbeError("tools/devctl.py run failed: %s" % ((err or out).strip() or "exit %d" % code))
            try:
                last = int(out.strip().splitlines()[-1])
            except (ValueError, IndexError):
                raise ProbeError("tools/devctl.py run printed no command id: %r" % out) from None
        code, out, err = self.devctl(["wait", str(last), "--timeout", "%g" % self.timeout])
        if code != 0:
            raise ProbeError(
                "the bridge driver did not run command %d (%s); is a dev build installed and the loop running "
                "(tools/devctl.py status)?" % (last, (err or out).strip() or "exit %d" % code)
            )
        deadline = self.clock() + self.timeout
        while True:
            parsed = parse_answers(self.read_from(offset), keys)
            if all(key in parsed.answers and parsed.answers[key].complete for key in keys):
                return [parsed.answers[key] for key in keys]
            if parsed.refusals:
                raise ProbeError("the bridge driver refused: %s" % "; ".join(parsed.refusals))
            if self.clock() >= deadline:
                missing = [
                    "%s %s%s" % (key[0], key[1], " (incomplete body)" if key in parsed.answers else "")
                    for key in keys
                    if key not in parsed.answers or not parsed.answers[key].complete
                ]
                raise ProbeError(
                    "no complete answer in %s within %g s for: %s" % (self.log_path, self.timeout, ", ".join(missing))
                )
            self.sleep(1.0)


# ---------------------------------------------------------------------------
# Watching
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Reading:
    """One poll: the smart scene, and in a probe its two scenes and one light."""

    stamp: str
    found: bool
    status: str
    state: str | None = None
    slot: tuple | None = None
    scenes: dict = dataclasses.field(default_factory=dict)
    light: dict | None = None

    def key(self):
        light = self.light or {}
        return (
            self.found,
            self.state,
            self.slot,
            tuple(sorted(self.scenes.items())),
            tuple(sorted(light.items())),
        )


def scene_status(answer):
    if not answer.ok:
        return answer.status
    return str(table(answer.item().get("status")).get("active") or "?")


def light_reading(answer, name):
    if not answer.ok:
        return {"name": name, "error": answer.status}
    item = answer.item()
    reading = {"name": str(table(item.get("metadata")).get("name") or name), "on": table(item.get("on")).get("on")}
    brightness = table(item.get("dimming")).get("brightness")
    if isinstance(brightness, (int, float)):
        reading["brightness"] = round(brightness, 1)
    ct = table(item.get("color_temperature"))
    if ct.get("mirek_valid") and isinstance(ct.get("mirek"), int):
        reading["mirek"] = ct["mirek"]
    else:
        xy = table(table(item.get("color")).get("xy"))
        if isinstance(xy.get("x"), (int, float)) and isinstance(xy.get("y"), (int, float)):
            reading["xy"] = "%.4f,%.4f" % (xy["x"], xy["y"])
    return reading


def light_text(light):
    if light.get("error"):
        return "%s %s" % (light["name"], light["error"])
    if light.get("on") is not True:
        return "%s off" % light["name"]
    text = "%s on" % light["name"]
    if "brightness" in light:
        text += " %g %%" % light["brightness"]
    if "mirek" in light:
        text += " mirek %d" % light["mirek"]
    elif "xy" in light:
        text += " xy %s" % light["xy"]
    return text


def describe(reading, names=None):
    """One watch line: "14:05:21.311 active, slot 0 (sunday 14:03) = A | A static, B inactive |
    Desk Lamp on 1 % mirek 454"."""
    if not reading.found:
        return "%s smart scene: %s" % (reading.stamp, reading.status)
    text = "%s %s" % (reading.stamp, reading.state or "?")
    if reading.slot:
        index, weekday, start, target = reading.slot
        text += ", slot %d (%s %s) = %s" % (index, weekday, start, (names or {}).get(target) or short(target))
    else:
        text += ", no active_timeslot"
    if reading.scenes:
        text += " | " + ", ".join("%s %s" % (key.upper(), value) for key, value in sorted(reading.scenes.items()))
    if reading.light:
        text += " | " + light_text(reading.light)
    return text


class Tracker:
    """The readings of one watch: what changed, and the verdict at the end."""

    def __init__(self, state=None):
        self.state = state
        self.first = {}  # event -> the stamp of the first reading that showed it
        self.values = {}  # event -> what that reading showed
        self.last_key = None
        self.previous_slot = None
        self.slot_changes = []
        self.stamps = []
        light = (state or {}).get("lights") or [{}]
        self.expected = light[0].get("mirek") or {}

    def names(self):
        if not self.state:
            return {}
        return {self.state.get("scene_a"): "A", self.state.get("scene_b"): "B"}

    def note(self, event, stamp, value=None):
        if event not in self.first:
            self.first[event] = stamp
            self.values[event] = value

    def add(self, reading):
        """Take a reading; returns its line, marked when something changed since the last."""
        key = reading.key()
        changed = self.last_key is not None and key != self.last_key
        self.last_key = key
        self.stamps.append(reading.stamp)
        if not reading.found:
            self.note("gone", reading.stamp, reading.status)
        else:
            if reading.state == "inactive":
                self.note("inactive", reading.stamp)
            slot = reading.slot[:3] if reading.slot else None
            if self.previous_slot is not None and slot != self.previous_slot:
                self.slot_changes.append((reading.stamp, self.previous_slot, slot))
            self.previous_slot = slot
            if self.state and reading.slot and reading.slot[3] == self.state.get("scene_b"):
                self.note("slot_b", reading.stamp)
        status_b = reading.scenes.get("b")
        if status_b and status_b not in ("inactive", "?") and not status_b.startswith("HTTP"):
            self.note("scene_b", reading.stamp, status_b)
        mirek = (reading.light or {}).get("mirek")
        if mirek is not None and self.expected:
            if mirek == self.expected.get("b"):
                self.note("mirek_b", reading.stamp, mirek)
            elif mirek != self.expected.get("a"):
                self.note("mirek_moved", reading.stamp, mirek)
        return describe(reading, self.names()) + ("   <- changed" if changed else "")

    def verdict(self):
        if not self.stamps:
            return ["verdict: no reading"]
        last = self.stamps[-1]
        lines = [
            "slot change at %s: %s -> %s" % (stamp, slot_label(before), slot_label(after))
            for stamp, before, after in self.slot_changes
        ]
        if self.state:
            slots = self.state.get("slots") or {}
            lead = (self.state.get("transition_ms") or 0) / 1000.0
            if "slot_b" in self.first:
                lines.append(
                    "verdict: slot B started, first seen %s (due %s; a %g s transition may start it up to %g s "
                    "earlier)" % (self.first["slot_b"], slots.get("b", "?"), lead, lead)
                )
            else:
                lines.append("verdict: slot B NOT seen by %s (due %s)" % (last, slots.get("b", "?")))
            if "scene_b" in self.first:
                lines.append("scene B: %s from %s" % (self.values["scene_b"], self.first["scene_b"]))
            else:
                lines.append("scene B: never left inactive")
            if self.expected.get("b") is not None:
                if "mirek_b" in self.first:
                    lines.append("light: mirek %d (scene B's) from %s" % (self.expected["b"], self.first["mirek_b"]))
                elif "mirek_moved" in self.first:
                    lines.append(
                        "light: mirek %s at %s, never scene B's %d"
                        % (self.values["mirek_moved"], self.first["mirek_moved"], self.expected["b"])
                    )
                else:
                    lines.append("light: never at scene B's mirek %d" % self.expected["b"])
        elif not self.slot_changes:
            lines.append("no slot change from %s to %s" % (self.stamps[0], last))
        if "inactive" in self.first:
            lines.append(
                "inactive from %s (group off, OFF, another scene or schedule on these lights end a schedule: "
                "research §7, V7 to V11)" % self.first["inactive"]
            )
        if "gone" in self.first:
            lines.append("smart scene %s from %s" % (self.values["gone"], self.first["gone"]))
        return lines


def slot_label(slot):
    if not slot:
        return "none"
    index, weekday, start = slot
    return "slot %d (%s %s)" % (index, weekday, start)


# ---------------------------------------------------------------------------
# The commands
# ---------------------------------------------------------------------------


def created_rid(answer, what):
    if not answer.ok:
        raise ProbeError("%s not created: %s" % (what, answer.problem()))
    for item in answer.data():
        if isinstance(item, dict) and isinstance(item.get("rid"), str):
            return item["rid"]
    raise ProbeError("%s: %s without a rid in the answer" % (what, answer.status))


class Probe:
    def __init__(self, loop, state_path, out=say, now=datetime.datetime.now, sleep=time.sleep):
        self.loop = loop
        self.state_path = state_path
        self.out = out
        self.now = now
        self.sleep = sleep

    def say(self, fmt, *args):
        self.out(fmt % args if args else fmt)

    def one(self, method, path, body=None):
        return self.loop.requests([(method, path, body)])[0]

    def require(self):
        state = load_state(self.state_path)
        if state is None:
            raise ProbeError("no probe: %s does not exist (create one first)" % self.state_path)
        if not state.get("smart_scene"):
            raise ProbeError("the probe in %s has no smart scene (create was cut off); run cleanup" % self.state_path)
        return state

    # create ------------------------------------------------------------------

    def post(self, state, name, path, body):
        """POST one resource named `name` with the state saved before and after; a missing answer
        leaves a `pending` note, for cleanup to look the resource up by name."""
        what = "%s %r" % ("smart scene" if name == PROBE_NAME else "scene", name)
        state["pending"] = name
        save_state(self.state_path, state)
        try:
            answer = self.one("POST", path, body)
        except ProbeError as exc:
            raise ProbeError("%s; the bridge may have made %s all the same: run cleanup" % (exc, what)) from exc
        del state["pending"]
        if not answer.ok:
            if any(state.get(key) for key in ("scene_a", "scene_b", "smart_scene")):
                save_state(self.state_path, state)
            else:
                os.remove(self.state_path)
        rid = created_rid(answer, what)
        for error in answer.errors():
            self.say("  note from the bridge: %s", error)
        return rid

    def create(
        self,
        group_rid,
        group_type="room",
        minutes=DEFAULT_MINUTES,
        brightness=DEFAULT_BRIGHTNESS,
        days="today",
        transition_ms=DEFAULT_TRANSITION_MS,
        allow_bright=False,
        allow_on=False,
        only=(),
    ):
        brightness = check_brightness(brightness, allow_bright)
        check_timing(minutes, transition_ms)
        if days not in ("today", "all"):
            raise ProbeError("--days is today or all, not %r" % (days,))
        if group_type not in ("room", "zone"):
            raise ProbeError("the group is a room or a zone, not %r" % (group_type,))
        if load_state(self.state_path) is not None:
            raise ProbeError("a probe exists already (%s): run cleanup first" % self.state_path)
        group_answer, lights_answer, bridge_answer = self.loop.requests(
            [
                ("GET", resource_path(group_type, group_rid), None),
                ("GET", resource_path("light"), None),
                ("GET", resource_path("bridge"), None),
            ]
        )
        if not group_answer.ok or not group_answer.item():
            raise ProbeError("the %s %s: %s" % (group_type, group_rid, group_answer.problem()))
        if not lights_answer.ok:
            raise ProbeError("the lights: %s" % lights_answer.problem())
        group = group_answer.item()
        group_name = str(table(group.get("metadata")).get("name") or group_rid)
        kept, left_out = member_lights(group, lights_answer.data(), only)
        for light in left_out:
            self.say("left out (cannot dim): %s", light["name"])
        if not kept:
            raise ProbeError("no light of %s %r can dim: nothing to probe with" % (group_type, group_name))
        lit = [light["name"] for light in kept if light["on"]]
        if lit and not allow_on:
            raise ProbeError(
                "%d of %d probe light(s) are on (%s): someone may be using %s; pick other lights (--light) or "
                "another %s, or pass --allow-on" % (len(lit), len(kept), ", ".join(lit), group_name, group_type)
            )
        grouped = [table(s).get("rid") for s in group.get("services") or [] if table(s).get("rtype") == "grouped_light"]
        bridge_tz = table(table(bridge_answer.item()).get("time_zone")).get("time_zone") if bridge_answer.ok else None
        state = {
            "schema": STATE_SCHEMA,
            "created_at": self.now().isoformat(timespec="seconds"),
            "group": {
                "rid": group_rid,
                "rtype": group_type,
                "name": group_name,
                "grouped_light": grouped[0] if grouped else None,
            },
            "lights": [
                {
                    "rid": light["rid"],
                    "name": light["name"],
                    "was_on": light["on"],
                    "mirek": (
                        {key: scene_mirek(light, SCENE_MIREK[key]) for key in ("a", "b")} if light["ct"] else None
                    ),
                }
                for light in kept
            ],
            "brightness": brightness,
            "minutes": minutes,
            "days": days,
            "transition_ms": transition_ms,
            "bridge_time_zone": bridge_tz,
        }
        self.say(
            "probe in %s %r: %d light(s) at %g %%: %s",
            group_type,
            group_name,
            len(kept),
            brightness,
            ", ".join(light["name"] for light in kept),
        )
        if lit:
            self.say("on before the probe (--allow-on; cleanup leaves them as the probe set them): %s", ", ".join(lit))
        self.say(
            "bridge time zone %s; slot times are this machine's local time (%s)",
            bridge_tz or "unknown",
            time.strftime("%Z"),
        )
        for key in ("a", "b"):
            body = scene_body(SCENE_NAME[key], group_rid, group_type, kept, brightness, SCENE_MIREK[key])
            state["scene_" + key] = self.post(state, SCENE_NAME[key], resource_path("scene"), body)
            save_state(self.state_path, state)
            self.say("scene %s %r (%d K): %s", key.upper(), SCENE_NAME[key], SCENE_KELVIN[key], state["scene_" + key])
        a, b = slot_times(self.now(), minutes)
        body = smart_scene_body(
            PROBE_NAME, group_rid, group_type, state["scene_a"], state["scene_b"], a, b, days, transition_ms
        )
        state["slots"] = {
            "a": hhmm(a),
            "b": hhmm(b),
            "a_at": a.isoformat(),
            "b_at": b.isoformat(),
            "recurrence": body["week_timeslots"][0]["recurrence"],
        }
        state["smart_scene"] = self.post(state, PROBE_NAME, resource_path("smart_scene"), body)
        save_state(self.state_path, state)
        self.say("smart scene %r: %s", PROBE_NAME, state["smart_scene"])
        self.say(
            "  slot A from %s, slot B from %s (%s), transition %g s",
            hhmm(a),
            hhmm(b),
            ", ".join(state["slots"]["recurrence"]),
            transition_ms / 1000.0,
        )
        self.say("  a new smart scene starts at once (research §7, V12): the probe lights show scene A now")
        self.say("state: %s", self.state_path)
        self.say("next: activate, watch (until %s), cleanup", hhmm(b + datetime.timedelta(minutes=AFTER_B_MINUTES)))
        return state

    # activate ----------------------------------------------------------------

    def activate(self):
        state = self.require()
        answer = self.one("PUT", resource_path("smart_scene", state["smart_scene"]), {"recall": {"action": "activate"}})
        if not answer.ok:
            raise ProbeError("activate: %s" % answer.problem())
        self.say("activate: %s at %s", answer.status, answer.stamp)
        tracker = Tracker(state)
        self.say(tracker.add(self.poll(state)))
        return state

    # watch -------------------------------------------------------------------

    def poll(self, state=None, smart=None, light=None):
        """One reading: GET the smart scene, and in a probe its scenes and its first light, in one tick."""
        smart_rid = smart or state["smart_scene"]
        batch = [("GET", resource_path("smart_scene", smart_rid), None)]
        if state:
            batch.append(("GET", resource_path("scene", state["scene_a"]), None))
            batch.append(("GET", resource_path("scene", state["scene_b"]), None))
        lights = (state or {}).get("lights") or []
        light_rid = light or (lights[0]["rid"] if lights else None)
        light_name = next((entry["name"] for entry in lights if entry["rid"] == light_rid), short(light_rid))
        if light_rid:
            batch.append(("GET", resource_path("light", light_rid), None))
        answers = self.loop.requests(batch)
        found = answers[0]
        reading = Reading(stamp=found.stamp, found=found.ok, status=found.status)
        if found.ok:
            item = found.item()
            reading.state = item.get("state")
            reading.slot = active_slot(item)
        if state:
            reading.scenes = {"a": scene_status(answers[1]), "b": scene_status(answers[2])}
        if light_rid:
            reading.light = light_reading(answers[-1], light_name)
        return reading

    def watch_end(self, until, state, now):
        if until:
            return until_time(until, now)
        b_at = ((state or {}).get("slots") or {}).get("b_at")
        if not b_at:
            raise ProbeError("--until HH:MM is needed with --smart")
        return max(datetime.datetime.fromisoformat(b_at) + datetime.timedelta(minutes=AFTER_B_MINUTES), now)

    def watch(self, until=None, interval=DEFAULT_INTERVAL_S, smart=None, light=None):
        if interval < MIN_INTERVAL_S:
            raise ProbeError("--interval %g is below %g s" % (interval, MIN_INTERVAL_S))
        state = None if smart else self.require()
        end = self.watch_end(until, state, self.now())
        tracker = Tracker(state)
        what = "smart scene %s" % smart if smart else "the probe (slot B due %s)" % state["slots"]["b"]
        self.say("watching %s every %g s until %s", what, interval, hhmm(end))
        failures = 0
        try:
            while True:
                started = self.now()
                try:
                    reading = self.poll(state, smart, light)
                except ProbeError as exc:
                    failures += 1
                    self.say("%s poll failed: %s", started.strftime("%H:%M:%S"), exc)
                    if failures >= MAX_POLL_FAILURES:
                        raise
                else:
                    failures = 0
                    self.say(tracker.add(reading))
                    if not reading.found:
                        break
                if self.now() >= end:
                    break
                pause = interval - (self.now() - started).total_seconds()
                if pause > 0:
                    self.sleep(min(pause, max((end - self.now()).total_seconds(), 0) + 0.1))
        finally:
            for line in tracker.verdict():
                self.say(line)
        return tracker

    # cleanup -----------------------------------------------------------------

    def lights_off(self, state):
        """Turn off the probe lights that were off before and still show about the probe's level."""
        level = float(state.get("brightness") or DEFAULT_BRIGHTNESS)
        lights = state.get("lights") or []
        before_on = [light["name"] for light in lights if light.get("was_on")]
        if before_on:
            self.say("left as the probe set them (they were on before): %s", ", ".join(before_on))
        off_before = [light for light in lights if not light.get("was_on")]
        if not off_before:
            return
        answers = self.loop.requests([("GET", resource_path("light", light["rid"]), None) for light in off_before])
        to_off = []
        for light, answer in zip(off_before, answers, strict=True):
            if not answer.ok:
                self.say("%s: %s; left as it is", light["name"], answer.problem())
                continue
            item = answer.item()
            if table(item.get("on")).get("on") is not True:
                continue
            now = table(item.get("dimming")).get("brightness")
            if isinstance(now, (int, float)) and now > level + CHANGED_ABOVE:
                self.say("%s is at %g %%, above the probe's %g %%: changed since, left on", light["name"], now, level)
                continue
            to_off.append(light)
        if not to_off:
            return
        answers = self.loop.requests(
            [("PUT", resource_path("light", light["rid"]), {"on": {"on": False}}) for light in to_off]
        )
        for light, answer in zip(to_off, answers, strict=True):
            self.say("%s off: %s", light["name"], answer.problem())

    def find_pending(self, state):
        """Look up what a cut-off create may have made (state["pending"], by name, in the group)."""
        name = state.get("pending")
        if not name:
            return []
        rtype = "smart_scene" if name == PROBE_NAME else "scene"
        answer = self.one("GET", resource_path(rtype))
        if not answer.ok:
            self.say("could not look for %r: %s; check the Hue app for it", name, answer.problem())
            return []
        known = {state.get(key) for key in ("scene_a", "scene_b", "smart_scene")}
        group_rid = table(state.get("group")).get("rid")
        found = []
        for item in answer.data():
            item = table(item)
            if (
                table(item.get("metadata")).get("name") == name
                and table(item.get("group")).get("rid") == group_rid
                and item.get("id") not in known
            ):
                found.append(("%s %r" % (rtype.replace("_", " "), name), resource_path(rtype, item["id"])))
        self.say("%r from the cut-off create: %s", name, "found %d" % len(found) if found else "not on the bridge")
        return found

    def cleanup(self, keep_lights=False):
        """Deactivate, delete, confirm, then the lights: the deletion comes before anything that
        could fail on the way, since a schedule left behind would go on switching the room."""
        state = load_state(self.state_path)
        if state is None:
            self.say("nothing to clean up: no %s", self.state_path)
            return True
        smart = state.get("smart_scene")
        if smart:
            # Stopped first, so no time slot starts while the rest goes.
            answer = self.one("PUT", resource_path("smart_scene", smart), {"recall": {"action": "deactivate"}})
            self.say("deactivate: %s", answer.problem())
        orphans = [tuple(target) for target in state.get("orphans") or []]
        if state.get("pending"):
            try:
                orphans += self.find_pending(state)
                del state["pending"]
            except ProbeError as exc:
                self.say("could not look for %r (%s); the next cleanup looks again", state["pending"], exc)
            state["orphans"] = [list(target) for target in orphans]
            save_state(self.state_path, state)
        smart_targets = [("smart scene %r" % PROBE_NAME, resource_path("smart_scene", smart))] if smart else []
        smart_targets += [target for target in orphans if "/smart_scene/" in target[1]]
        scene_targets = [
            ("scene %s" % key.upper(), resource_path("scene", state["scene_" + key]))
            for key in ("a", "b")
            if state.get("scene_" + key)
        ]
        scene_targets += [target for target in orphans if "/scene/" in target[1]]
        # The smart scene first: deleting a scene it plays deletes it as well a second later
        # (research §7, V14), and the log reads more plainly in this order.
        for targets in (smart_targets, scene_targets):
            if targets:
                answers = self.loop.requests([("DELETE", path, None) for _, path in targets])
                for (label, _), answer in zip(targets, answers, strict=True):
                    self.say("delete %s: %s", label, answer.problem())
        left = []
        targets = smart_targets + scene_targets
        if targets:
            answers = self.loop.requests([("GET", path, None) for _, path in targets])
            for (label, path), answer in zip(targets, answers, strict=True):
                if answer.code == 404:
                    self.say("gone: %s", label)
                else:
                    self.say("STILL THERE: %s (%s, %s)", label, path, answer.status)
                    left.append(label)
        if not keep_lights:
            try:
                self.lights_off(state)
            except ProbeError as exc:
                self.say("probe lights not switched off (%s): switch them off by hand if they show the probe", exc)
        if state.get("pending"):
            left.append("%r (not looked up)" % state["pending"])
        if left:
            save_state(self.state_path, state)
            raise ProbeError("still to remove: %s; run cleanup again" % ", ".join(left))
        os.remove(self.state_path)
        self.say("all gone; %s removed", self.state_path)
        return True

    # run ---------------------------------------------------------------------

    def run(self, interval=DEFAULT_INTERVAL_S, **create_args):
        try:
            self.create(**create_args)
            self.activate()
            self.watch(interval=interval)
        finally:
            if os.path.exists(self.state_path):
                self.say("cleanup (if this is cut off: smart_scene_probe.py cleanup)")
                try:
                    self.cleanup()
                except ProbeError as exc:
                    self.say("cleanup failed: %s", exc)


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def add_create_options(parser):
    where = parser.add_mutually_exclusive_group(required=True)
    where.add_argument("--room", metavar="RID", help="the room's rid (its lights are its devices' lights)")
    where.add_argument("--zone", metavar="RID", help="a zone's rid instead of a room's")
    parser.add_argument(
        "--minutes", type=int, default=DEFAULT_MINUTES, help="slot B starts this long after slot A (default 3)"
    )
    parser.add_argument(
        "--brightness", type=float, default=DEFAULT_BRIGHTNESS, help="every probe light's level in %% (default 1)"
    )
    parser.add_argument("--allow-bright", action="store_true", help="allow a brightness above 5 %%")
    parser.add_argument(
        "--days",
        choices=("today", "all"),
        default="today",
        help="slots on today's weekday only (default), or on every weekday as the app's own schedules",
    )
    parser.add_argument(
        "--transition-ms",
        type=int,
        default=DEFAULT_TRANSITION_MS,
        help="the smart scene's transition_duration (default 60000, the app's)",
    )
    parser.add_argument(
        "--light", action="append", default=[], metavar="RID", help="only this light of the group (repeatable)"
    )
    parser.add_argument("--allow-on", action="store_true", help="go ahead although probe lights are on")


def create_args(args):
    return {
        "group_rid": args.room or args.zone,
        "group_type": "room" if args.room else "zone",
        "minutes": args.minutes,
        "brightness": args.brightness,
        "days": args.days,
        "transition_ms": args.transition_ms,
        "allow_bright": args.allow_bright,
        "allow_on": args.allow_on,
        "only": tuple(args.light),
    }


def build_parser():
    parser = argparse.ArgumentParser(
        prog="smart_scene_probe.py",
        description="Do API-made Hue time-based scenes (smart_scene) run their slot changes? (issue #40)",
        epilog="Every request goes through the dev loop (tools/devctl.py); see the module docstring.",
    )
    parser.add_argument(
        "--state-dir",
        default=DEFAULT_STATE_DIR,
        help="the dev server's state directory, holding driver.log (default %(default)s)",
    )
    parser.add_argument("--state-file", default=None, help="the probe's ids (default <state-dir>/%s)" % STATE_NAME)
    parser.add_argument(
        "--timeout", type=float, default=DEFAULT_TIMEOUT_S, help="seconds to wait for each batch of answers"
    )
    sub = parser.add_subparsers(dest="cmd", metavar="command", required=True)
    add_create_options(sub.add_parser("create", help="make the two scenes and the smart scene"))
    sub.add_parser("activate", help="recall the probe with action activate")
    p = sub.add_parser("watch", help="poll the probe (or --smart) and print state and slot changes")
    p.add_argument("--until", metavar="HH:MM", help="stop at this local time (default: 3 min after slot B)")
    p.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_S, help="seconds between polls (default 20)")
    p.add_argument("--smart", metavar="RID", help="watch this smart scene instead of the probe")
    p.add_argument("--light", metavar="RID", help="with --smart: also show this light")
    p = sub.add_parser("cleanup", help="deactivate, lights off, delete everything, confirm")
    p.add_argument("--keep-lights", action="store_true", help="leave the probe lights as they are")
    p = sub.add_parser("run", help="create, activate, watch, cleanup")
    add_create_options(p)
    p.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_S, help="seconds between polls (default 20)")
    return parser


def main(argv=None, loop=None, out=say):
    args = build_parser().parse_args(argv)
    state_path = args.state_file or os.path.join(args.state_dir, STATE_NAME)
    probe = Probe(loop or DevLoop(state_dir=args.state_dir, timeout=args.timeout), state_path, out=out)
    try:
        if args.cmd == "create":
            probe.create(**create_args(args))
        elif args.cmd == "activate":
            probe.activate()
        elif args.cmd == "watch":
            if args.light and not args.smart:
                raise ProbeError("--light goes with --smart (a probe watches its own first light)")
            probe.watch(until=args.until, interval=args.interval, smart=args.smart, light=args.light)
        elif args.cmd == "cleanup":
            probe.cleanup(keep_lights=args.keep_lights)
        elif args.cmd == "run":
            probe.run(interval=args.interval, **create_args(args))
        return 0
    except ProbeError as exc:
        sys.stderr.write("smart_scene_probe: %s\n" % exc)
        return 1
    except KeyboardInterrupt:
        sys.stderr.write("smart_scene_probe: interrupted\n")
        return 130


if __name__ == "__main__":
    sys.exit(main())
