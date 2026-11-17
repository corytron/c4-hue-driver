"""Unit tests for tools/fakebox/mdns.py (#547, docs/fakebox-design.md §5): the fake sync box's answer to
the drivers' legacy unicast query for _huesync._tcp.local.

The answers are read back by a decoder of this file (written apart from the module's encoder) and, when
lua5.1 is installed, by the box driver's own code: src/common/mdns.lua's window, and a whole search of
src/hue_syncbox/syncbox/discovery.lua whose query goes through `mdns.py answer`. Nothing binds port
5353 except LiveTest, which shares it as avahi does and skips when it cannot, or when multicast does not
loop back to this host; it tells its answer from any other responder's by a random name.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_mdns.py -v
"""

import os
import random
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

from fakebox import mdns  # noqa: E402

SCRIPT = os.path.join(TOOLS, "fakebox", "mdns.py")
BOX = "0A1B2C3D4E5F"
OTHER_BOX = "0A1B2C3D4E60"
ADDRESS = "192.0.2.7"  # the VM's placeholder
OTHER_ADDRESS = "10.0.2.150"  # the box's placeholder
QUERIER = ("192.0.2.40", 6008)  # a controller's discovery binding (TEST-NET-1)
LUA = shutil.which("lua5.1")

# The question the drivers send for id 0x03e9 (src/common/mdns.lua query, printed by lua5.1).
DRIVER_QUERY_1001 = bytes.fromhex("03e900000001000000000000085f68756573796e63045f746370056c6f63616c00000c0001")


# A decoder of DNS messages, apart from the module's -------------------------------------------------


def read_name(data, pos):
    """(name, next offset); every pointer must point back to an earlier offset."""
    labels, end, jumps = [], None, 0
    while True:
        size = data[pos]
        if size == 0:
            pos += 1
            break
        if size >= 0xC0:
            target = ((size & 0x3F) << 8) | data[pos + 1]
            assert target < pos, "a pointer that does not point back"
            jumps += 1
            assert jumps < 20
            if end is None:
                end = pos + 2
            pos = target
            continue
        assert size < 64
        labels.append(data[pos + 1 : pos + 1 + size].decode("utf-8"))
        pos += 1 + size
    return ".".join(labels), (end if end is not None else pos)


def decode(data):
    qid, flags, qd, an, ns, ar = struct.unpack_from("!HHHHHH", data, 0)
    pos, questions, records = 12, [], []
    for _ in range(qd):
        name, pos = read_name(data, pos)
        qtype, qclass = struct.unpack_from("!HH", data, pos)
        pos += 4
        questions.append((name, qtype, qclass))
    for section in ["an"] * an + ["ns"] * ns + ["ar"] * ar:
        name, pos = read_name(data, pos)
        rtype, rclass, ttl, rlen = struct.unpack_from("!HHIH", data, pos)
        pos += 10
        rdata, stop = data[pos : pos + rlen], pos + rlen
        assert stop <= len(data), "a record runs past the packet"
        if rtype == mdns.TYPE_PTR:
            value, after = read_name(data, pos)
            assert after == stop
        elif rtype == mdns.TYPE_SRV:
            prio, weight, port = struct.unpack_from("!HHH", data, pos)
            target, after = read_name(data, pos + 6)
            assert after == stop
            value = (prio, weight, port, target)
        elif rtype == mdns.TYPE_TXT:
            items, i = [], 0
            while i < len(rdata):
                items.append(rdata[i + 1 : i + 1 + rdata[i]].decode("utf-8"))
                i += 1 + rdata[i]
            assert i == len(rdata)
            value = items
        elif rtype == mdns.TYPE_A:
            assert rlen == 4
            value = socket.inet_ntoa(rdata)
        else:
            value = rdata
        records.append({"section": section, "name": name, "type": rtype, "class": rclass, "ttl": ttl, "data": value})
        pos = stop
    assert pos == len(data), "bytes after the last record"
    return {"id": qid, "flags": flags, "questions": questions, "records": records}


def decode_records_after(data, pos):
    """The records' names and types of an answer whose questions end at `pos`, for questions the
    decoder cannot read (labels that are not UTF-8)."""
    _, _, _, an, ns, ar = struct.unpack_from("!HHHHHH", data, 0)
    records = []
    for section in ["an"] * an + ["ns"] * ns + ["ar"] * ar:
        name, pos = read_name(data, pos)
        rtype, rclass, ttl, rlen = struct.unpack_from("!HHIH", data, pos)
        pos += 10 + rlen
        records.append({"section": section, "name": name, "type": rtype})
    assert pos == len(data)
    return records


def question(name, qtype=mdns.TYPE_PTR, qclass=mdns.CLASS_IN, qid=0x1234, extra=()):
    """A query with these questions (no compression), for questions the drivers do not send."""
    out = struct.pack("!HHHHHH", qid, 0, 1 + len(extra), 0, 0, 0)
    for n, t, c in ((name, qtype, qclass), *extra):
        for label in n.split("."):
            out += bytes([len(label)]) + label.encode()
        out += b"\0" + struct.pack("!HH", t, c)
    return out


def by_type(decoded, rtype, section=None):
    return [r for r in decoded["records"] if r["type"] == rtype and (section is None or r["section"] == section)]


def txt_dict(items):
    return dict(item.split("=", 1) for item in items)


# The answer ---------------------------------------------------------------------------------------------


class QueryTest(unittest.TestCase):
    def test_service_query_is_the_drivers_question(self):
        self.assertEqual(mdns.service_query(1001), DRIVER_QUERY_1001)
        self.assertEqual(mdns.service_query(65536 + 7)[:2], b"\x00\x07")


class LegacyAnswerTest(unittest.TestCase):
    def setUp(self):
        self.box = mdns.Box(BOX.lower(), "HSB2", name="Living Room", port=8443)
        self.data = mdns.build_answer(DRIVER_QUERY_1001, [self.box], address=ADDRESS)
        self.decoded = decode(self.data)

    def test_the_id_and_the_question_are_repeated(self):
        d = self.decoded
        self.assertEqual(d["id"], 1001)
        self.assertEqual(d["flags"], 0x8400)
        self.assertEqual(d["questions"], [("_huesync._tcp.local", mdns.TYPE_PTR, mdns.CLASS_IN)])

    def test_ptr_in_the_answers_srv_txt_a_in_the_additionals(self):
        d = self.decoded
        self.assertEqual(
            [(r["section"], r["type"]) for r in d["records"]], [("an", 12), ("ar", 33), ("ar", 16), ("ar", 1)]
        )
        instance = "HueSyncBox-%s._huesync._tcp.local" % BOX
        ptr, srv, txt, a = d["records"]
        self.assertEqual((ptr["name"], ptr["data"]), ("_huesync._tcp.local", instance))
        self.assertEqual((srv["name"], srv["data"]), (instance, (0, 0, 8443, BOX + ".local")))
        self.assertEqual(txt["name"], instance)
        self.assertEqual(
            txt_dict(txt["data"]), {"name": "Living Room", "devicetype": "HSB2", "uniqueid": BOX, "path": "/api"}
        )
        self.assertEqual((a["name"], a["data"]), (BOX + ".local", ADDRESS))

    def test_legacy_ttls_and_no_cache_flush(self):
        for r in self.decoded["records"]:
            self.assertLessEqual(r["ttl"], 10, r)
            self.assertGreater(r["ttl"], 0, r)
            self.assertEqual(r["class"], mdns.CLASS_IN, r)

    def test_names_after_the_first_are_compressed(self):
        # The service name is written once, in the question; the instance once, in the PTR.
        self.assertEqual(self.data.count(b"\x08_huesync"), 1)
        self.assertEqual(self.data.count(("HueSyncBox-" + BOX).encode()), 1)
        self.assertEqual(self.data.count(b"\x05local"), 1)
        self.assertLess(len(self.data), 512)

    def test_the_box_address_wins_over_the_default(self):
        box = mdns.Box(BOX, address=OTHER_ADDRESS)
        d = decode(mdns.build_answer(DRIVER_QUERY_1001, [box], address=ADDRESS))
        self.assertEqual([r["data"] for r in by_type(d, mdns.TYPE_A)], [OTHER_ADDRESS])

    def test_no_address_at_all_is_an_error(self):
        with self.assertRaises(ValueError):
            mdns.build_answer(DRIVER_QUERY_1001, [mdns.Box(BOX)])

    def test_several_boxes_in_one_answer(self):
        boxes = [mdns.Box(BOX, "HSB2", name="Den"), mdns.Box(OTHER_BOX, "HSB1", name="Bar", address=OTHER_ADDRESS)]
        d = decode(mdns.build_answer(DRIVER_QUERY_1001, boxes, address=ADDRESS))
        self.assertEqual(len(by_type(d, mdns.TYPE_PTR, "an")), 2)
        srv = {r["name"]: r["data"][3] for r in by_type(d, mdns.TYPE_SRV)}
        self.assertEqual(
            srv,
            {
                "HueSyncBox-%s._huesync._tcp.local" % BOX: BOX + ".local",
                "HueSyncBox-%s._huesync._tcp.local" % OTHER_BOX: OTHER_BOX + ".local",
            },
        )
        a = {r["name"]: r["data"] for r in by_type(d, mdns.TYPE_A)}
        self.assertEqual(a, {BOX + ".local": ADDRESS, OTHER_BOX + ".local": OTHER_ADDRESS})
        self.assertEqual(d["records"][-1]["type"], mdns.TYPE_A)
        self.assertEqual(d["records"][-2]["type"], mdns.TYPE_A)


class MulticastAnswerTest(unittest.TestCase):
    def test_an_mdns_response_has_id_zero_no_question_and_cache_flush(self):
        box = mdns.Box(BOX, "HSB3")
        d = decode(mdns.build_answer(DRIVER_QUERY_1001, [box], legacy=False, address=ADDRESS))
        self.assertEqual((d["id"], d["flags"], d["questions"]), (0, 0x8400, []))
        classes = {r["type"]: r["class"] for r in d["records"]}
        ttls = {r["type"]: r["ttl"] for r in d["records"]}
        self.assertEqual(classes[mdns.TYPE_PTR], mdns.CLASS_IN)
        for rtype in (mdns.TYPE_SRV, mdns.TYPE_TXT, mdns.TYPE_A):
            self.assertEqual(classes[rtype], 0x8001)
        self.assertEqual(ttls, {12: 4500, 33: 120, 16: 4500, 1: 120})


class QuestionsTest(unittest.TestCase):
    boxes = [mdns.Box(BOX, address=ADDRESS), mdns.Box(OTHER_BOX, address=OTHER_ADDRESS)]

    def answer(self, *args, **kwargs):
        data = mdns.build_answer(question(*args, **kwargs), self.boxes)
        return None if data is None else decode(data)

    def test_the_service_name_in_any_case_and_type_any(self):
        d = self.answer("_HueSync._TCP.Local", mdns.TYPE_ANY)
        self.assertEqual(len(by_type(d, mdns.TYPE_PTR, "an")), 2)
        self.assertEqual(d["questions"][0][0], "_HueSync._TCP.Local")

    def test_the_services_meta_query(self):
        d = self.answer("_services._dns-sd._udp.local")
        self.assertEqual([(r["type"], r["data"]) for r in d["records"]], [(12, "_huesync._tcp.local")])

    def test_an_instance_srv_and_txt(self):
        instance = "HueSyncBox-%s._huesync._tcp.local" % OTHER_BOX
        d = self.answer(instance, mdns.TYPE_SRV)
        self.assertEqual([(r["section"], r["type"]) for r in d["records"]], [("an", 33), ("ar", 1)])
        self.assertEqual(d["records"][1]["data"], OTHER_ADDRESS)
        d = self.answer(instance.lower(), mdns.TYPE_TXT)
        self.assertEqual([(r["section"], r["type"]) for r in d["records"]], [("an", 16)])
        d = self.answer(instance, mdns.TYPE_ANY)
        self.assertEqual(sorted(r["type"] for r in d["records"]), [1, 16, 33])

    def test_a_host_name(self):
        d = self.answer(BOX.lower() + ".local", mdns.TYPE_A)
        self.assertEqual([(r["type"], r["data"]) for r in d["records"]], [(1, ADDRESS)])
        self.assertIsNone(self.answer(BOX + ".local", mdns.TYPE_AAAA))

    def test_repeated_questions_give_each_record_once(self):
        d = self.answer("_huesync._tcp.local", extra=[("_huesync._tcp.local", mdns.TYPE_PTR, mdns.CLASS_IN)])
        self.assertEqual(len(d["questions"]), 2)
        self.assertEqual(len(by_type(d, mdns.TYPE_PTR)), 2)
        self.assertEqual(len(by_type(d, mdns.TYPE_SRV)), 2)

    def test_odd_questions_are_repeated_byte_for_byte(self):
        head = struct.pack("!HHHHHH", 7, 0, 3, 0, 0, 0)
        service = b"\x08_huesync\x04_tcp\x05local\x00" + struct.pack("!HH", mdns.TYPE_PTR, mdns.CLASS_IN)
        # The instance, its service part a pointer to the first question (offset 12).
        instance = b"\x17HueSyncBox-" + BOX.encode() + b"\xc0\x0c" + struct.pack("!HH", mdns.TYPE_SRV, mdns.CLASS_IN)
        # A label holding a dot and a label that is not UTF-8.
        odd = b"\x03a.b\x02\xff\xfe\x00" + struct.pack("!HH", mdns.TYPE_A, mdns.CLASS_IN)
        query = head + service + instance + odd
        data = mdns.build_answer(query, self.boxes)
        self.assertEqual(data[:2], b"\x00\x07")
        self.assertEqual(data[4:6], b"\x00\x03")
        self.assertEqual(data[12 : len(query)], query[12:])
        types = [(r["section"], r["type"]) for r in decode_records_after(data, len(query))]
        # Both PTRs and the SRV asked for; the rest of both boxes, A records last; no record twice.
        self.assertEqual(
            types, [("an", 12), ("an", 12), ("an", 33), ("ar", 16), ("ar", 33), ("ar", 16), ("ar", 1), ("ar", 1)]
        )

    def test_what_is_not_ours_gets_nothing(self):
        self.assertIsNone(self.answer("_hue._tcp.local"))
        self.assertIsNone(self.answer("_huesync._udp.local"))
        self.assertIsNone(self.answer("_huesync._tcp.local", mdns.TYPE_SRV))
        self.assertIsNone(self.answer("_huesync._tcp.local", qclass=3))  # class CH
        self.assertIsNone(self.answer("HueSyncBox-FFFFFFFFFFFF._huesync._tcp.local", mdns.TYPE_SRV))
        self.assertIsNone(mdns.build_answer(DRIVER_QUERY_1001, []))


class MalformedTest(unittest.TestCase):
    boxes = [mdns.Box(BOX, address=ADDRESS)]

    def test_what_is_not_a_query_gets_nothing(self):
        answer = mdns.build_answer(DRIVER_QUERY_1001, self.boxes)
        cases = {
            "an answer": answer,
            "empty": b"",
            "a header only": DRIVER_QUERY_1001[:12],
            "no question": b"\x00\x01" + b"\x00" * 10,
            "17 questions": DRIVER_QUERY_1001[:4] + b"\x00\x11" + DRIVER_QUERY_1001[6:],
            "opcode 2": DRIVER_QUERY_1001[:2] + b"\x10\x00" + DRIVER_QUERY_1001[4:],
            "a pointer to itself": DRIVER_QUERY_1001[:12] + b"\xc0\x0c\x00\x0c\x00\x01",
            "a pointer ahead": DRIVER_QUERY_1001[:12] + b"\xc0\x20\x00\x0c\x00\x01" + b"\x00" * 30,
            "a label of 64": DRIVER_QUERY_1001[:12] + b"\x40" + b"a" * 64 + b"\x00\x00\x0c\x00\x01",
            "no type": DRIVER_QUERY_1001[:-4],
            "too long": DRIVER_QUERY_1001 + b"\x00" * 9000,
            "not bytes": "a string",
            "None": None,
        }
        for why, data in cases.items():
            self.assertIsNone(mdns.build_answer(data, self.boxes), why)

    def test_every_cut_and_random_bytes_never_raise(self):
        for i in range(len(DRIVER_QUERY_1001)):
            self.assertIsNone(mdns.build_answer(DRIVER_QUERY_1001[:i], self.boxes))
        rng = random.Random(547)
        for _ in range(3000):
            data = bytearray(DRIVER_QUERY_1001)
            for _ in range(rng.randint(1, 6)):
                data[rng.randrange(len(data))] = rng.randrange(256)
            result = mdns.build_answer(bytes(data), self.boxes)
            if result is not None:
                decode(result)
            mdns.build_answer(bytes(rng.randrange(256) for _ in range(rng.randint(0, 80))), self.boxes)

    def test_a_long_compressed_name_is_refused(self):
        # A name over 255 bytes made of pointers back to one 63-byte label run.
        head = struct.pack("!HHHHHH", 1, 0, 2, 0, 0, 0)
        first = b"\x3f" + b"a" * 63 + b"\x3f" + b"b" * 63 + b"\x3f" + b"c" * 63 + b"\x00" + b"\x00\x0c\x00\x01"
        second = b"\x3f" + b"d" * 63 + b"\xc0\x0c" + b"\x00\x0c\x00\x01"
        self.assertIsNone(mdns.build_answer(head + first + second, self.boxes))


class BoxTest(unittest.TestCase):
    def test_a_box_keeps_its_id_upper_case(self):
        box = mdns.Box("0a1b2c3d4e5f")
        self.assertEqual(box.box_id, BOX)
        self.assertEqual(box.instance, "HueSyncBox-" + BOX)
        self.assertEqual(box.host, BOX + ".local")
        self.assertEqual((box.model, box.port, box.path), ("HSB2", 443, "/api"))

    def test_bad_values_are_refused(self):
        for kwargs in (
            {"box_id": "0A1B2C3D4E5"},
            {"box_id": "0A1B2C3D4E5G"},
            {"box_id": None},
            {"box_id": BOX, "model": ""},
            {"box_id": BOX, "model": "HSB 2"},
            {"box_id": BOX, "port": 0},
            {"box_id": BOX, "port": 65536},
            {"box_id": BOX, "port": True},
            {"box_id": BOX, "port": "443"},
            {"box_id": BOX, "address": "192.0.2.256"},
            {"box_id": BOX, "address": "::1"},
            {"box_id": BOX, "name": ""},
            {"box_id": BOX, "name": "x" * 251},
        ):
            with self.assertRaises(ValueError, msg=repr(kwargs)):
                mdns.Box(**kwargs)
        self.assertEqual(len(mdns.Box(BOX, name="x" * 250).txt()[0]), 255)

    def test_parse_box(self):
        self.assertEqual(mdns.parse_box("HSB2:" + BOX.lower()), mdns.Box(BOX, "HSB2"))
        self.assertEqual(mdns.parse_box("HSB1:%s:8443:Den: TV" % BOX), mdns.Box(BOX, "HSB1", port=8443, name="Den: TV"))
        self.assertEqual(mdns.parse_box("HSB3:" + BOX, port=8444).port, 8444)
        for bad in ("HSB2", "HSB2:nothex", "HSB2:%s:http" % BOX):
            with self.assertRaises(ValueError, msg=bad):
                mdns.parse_box(bad)


class ResponderHandleTest(unittest.TestCase):
    """Where each answer goes, without a socket."""

    def setUp(self):
        self.boxes = [mdns.Box(BOX, name="Den"), mdns.Box(OTHER_BOX, name="Bar", port=8444)]
        self.responder = mdns.Responder(self.boxes, address=ADDRESS)

    def test_a_legacy_query_gets_one_unicast_answer_per_box(self):
        out = self.responder.handle(DRIVER_QUERY_1001, QUERIER)
        self.assertEqual([dest for _, dest in out], [QUERIER, QUERIER])
        decoded = [decode(packet) for packet, _ in out]
        self.assertEqual([d["id"] for d in decoded], [1001, 1001])
        self.assertEqual([txt_dict(by_type(d, mdns.TYPE_TXT)[0]["data"])["name"] for d in decoded], ["Den", "Bar"])

    def test_one_datagram_for_every_box_when_asked(self):
        responder = mdns.Responder(self.boxes, address=ADDRESS, separate=False)
        out = responder.handle(DRIVER_QUERY_1001, QUERIER)
        self.assertEqual(len(out), 1)
        self.assertEqual(len(by_type(decode(out[0][0]), mdns.TYPE_PTR)), 2)

    def test_a_query_from_5353_is_answered_to_the_group(self):
        out = self.responder.handle(DRIVER_QUERY_1001, ("192.0.2.41", 5353))
        self.assertEqual({dest for _, dest in out}, {(mdns.GROUP, mdns.PORT)})
        self.assertEqual(decode(out[0][0])["id"], 0)

    def test_a_qu_question_from_5353_is_answered_to_the_sender(self):
        query = question("_huesync._tcp.local", qclass=0x8001)
        out = self.responder.handle(query, ("192.0.2.41", 5353))
        self.assertEqual({dest for _, dest in out}, {("192.0.2.41", 5353)})
        self.assertEqual(decode(out[0][0])["questions"], [])

    def test_nothing_for_garbage_or_an_answer(self):
        self.assertEqual(self.responder.handle(b"\x00" * 3, QUERIER), [])
        answer = self.responder.handle(DRIVER_QUERY_1001, QUERIER)[0][0]
        self.assertEqual(self.responder.handle(answer, ("192.0.2.41", 5353)), [])

    def test_set_boxes_changes_the_answer(self):
        self.responder.set_boxes([mdns.Box(BOX, name="Renamed")])
        out = self.responder.handle(DRIVER_QUERY_1001, QUERIER)
        self.assertEqual(len(out), 1)
        self.assertEqual(txt_dict(by_type(decode(out[0][0]), mdns.TYPE_TXT)[0]["data"])["name"], "Renamed")
        with self.assertRaises(TypeError):
            self.responder.set_boxes(["HSB2:" + BOX])


class CLITest(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", SCRIPT, *args], capture_output=True, text=True, check=False)

    def test_answer_prints_one_datagram_a_box(self):
        proc = self.run_cli(
            "answer", "--box", "HSB2:%s:8443:Den" % BOX, "--box", "HSB1:" + OTHER_BOX, "--address", ADDRESS,
            DRIVER_QUERY_1001.hex(),
        )  # fmt: skip
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.split()
        self.assertEqual(len(lines), 2)
        first, second = (decode(bytes.fromhex(line)) for line in lines)
        self.assertEqual(by_type(first, mdns.TYPE_SRV)[0]["data"][2], 8443)
        self.assertEqual(by_type(second, mdns.TYPE_SRV)[0]["data"][2], 443)
        self.assertEqual(first["id"], 1001)

    def test_answer_multicast_and_port_default(self):
        proc = self.run_cli(
            "answer", "--multicast", "--port", "8443", "--box", "HSB2:" + BOX, "--address", ADDRESS,
            DRIVER_QUERY_1001.hex(),
        )  # fmt: skip
        d = decode(bytes.fromhex(proc.stdout.strip()))
        self.assertEqual((d["id"], d["questions"]), (0, []))
        self.assertEqual(by_type(d, mdns.TYPE_SRV)[0]["data"][2], 8443)

    def test_a_bad_box_is_refused(self):
        proc = self.run_cli("answer", "--box", "HSB2:nothex", "--address", ADDRESS, DRIVER_QUERY_1001.hex())
        self.assertEqual(proc.returncode, 1)
        self.assertIn("12 hex digits", proc.stderr)


# The driver's own parser --------------------------------------------------------------------------------

LUA_HARNESS = r"""
local root, mode = arg[1], arg[2]
package.path = root .. "/src/hue_syncbox/?.lua;" .. root .. "/src/?.lua;" .. package.path
local discovery = require("syncbox.discovery")
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end
local function shq(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function row(r)
	print(table.concat({ "row", tostring(r.id), tostring(r.raw_id), tostring(r.model), tostring(r.name),
		tostring(r.instance), tostring(r.ip), tostring(r.port), tostring(r.via) }, "\t"))
end

if mode == "query" then
	-- arg[3..]: query ids; the driver's question for each
	local m = discovery.new_mdns()
	for i = 3, #arg do print(hex(m.query(tonumber(arg[i])))) end
elseif mode == "take" then
	-- arg[3]: the window's query id, arg[4]: the sender ("-" for none, OS 3.x), arg[5..]: answers in hex
	local m = discovery.new_mdns()
	local w = m.window(tonumber(arg[3]))
	local from = arg[4] ~= "-" and arg[4] or nil
	for i = 5, #arg do
		local rows, why = w:take(unhex(arg[i]), from)
		if not rows then print("refused\t" .. tostring(why)) end
		for _, r in ipairs(rows or {}) do row(r) end
	end
elseif mode == "search" then
	-- arg[3]: python, arg[4]: mdns.py, arg[5]: identities "ip=ID/MODEL/NAME,..." (what GET /device
	-- answers at each address), arg[6..]: the arguments of `mdns.py answer` before the query
	local python, script = arg[3], arg[4]
	local who = {}
	for ip, id, model, name in arg[5]:gmatch("([^=,]+)=([^/]+)/([^/]+)/([^,]+)") do
		who[ip] = { id = id, model = model, name = name }
	end
	local answer_args = {}
	for i = 6, #arg do answer_args[#answer_args + 1] = shq(arg[i]) end
	local clock, timers, d = 1000000, {}, nil
	local function timer(ms, fn)
		local t = { due = clock + ms, fn = fn, seq = #timers + 1 }
		function t:Cancel() self.cancelled = true end
		timers[#timers + 1] = t
		return t
	end
	local net = {
		create = function() end, connect = function() end, disconnect = function() end,
		send = function(binding, port, data)
			print("query\t" .. hex(data))
			local cmd = shq(python) .. " -I " .. shq(script) .. " answer " .. table.concat(answer_args, " ")
				.. " " .. hex(data)
			local p = assert(io.popen(cmd))
			for line in p:lines() do
				local answer = unhex(line)
				timer(5, function() d:received(binding, port, answer, nil) end)
			end
			p:close()
		end,
	}
	local quiet = function() end
	d = discovery.new({
		identity_for = function(ip, cb)
			local dev = who[ip]
			timer(10, function()
				if dev then
					local device = { id = dev.id, model = dev.model, name = dev.name, device_type = dev.model }
					cb({ ok = true, device = device })
				else
					cb({ ok = false, reason = "no answer" })
				end
			end)
		end,
		timer = timer, net = net, now = function() return clock end,
		log = { debug = quiet, info = quiet, warn = function(f, ...) io.stderr:write(string.format(f, ...), "\n") end },
	})
	local result, detail
	d:search(function(list, det) result, detail = list, det end)
	d:status_changed(d.binding, 5353, "ONLINE")
	for _ = 1, 10000 do
		if result then break end
		local best
		for _, t in ipairs(timers) do
			if not t.cancelled and not t.done and (not best or t.due < best.due
				or (t.due == best.due and t.seq < best.seq)) then
				best = t
			end
		end
		if not best then break end
		best.done = true
		if best.due > clock then clock = best.due end
		best.fn()
	end
	print("text\t" .. tostring(detail and detail.text))
	for _, it in ipairs(result or {}) do
		print(table.concat({ "box", it.id, it.name, it.model, it.address }, "\t"))
	end
	for _, dr in ipairs(detail and detail.dropped or {}) do print("dropped\t" .. dr.address .. "\t" .. dr.why) end
end
"""


@unittest.skipUnless(LUA, "lua5.1 is not installed")
class DriverParserTest(unittest.TestCase):
    """The box driver's own Lua takes the fake's answers (src/common/mdns.lua, syncbox/discovery.lua)."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.harness = os.path.join(cls.tmp.name, "harness.lua")
        with open(cls.harness, "w", encoding="utf-8") as handle:
            handle.write(LUA_HARNESS)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def lua(self, *args):
        proc = subprocess.run([LUA, self.harness, ROOT, *args], capture_output=True, text=True, check=False)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return [line.split("\t") for line in proc.stdout.splitlines()]

    def take(self, query_id, sender, *packets):
        return self.lua("take", str(query_id), sender or "-", *(p.hex() for p in packets))

    def test_the_drivers_question_is_service_query(self):
        ids = [1, 1001, 4660, 65535]
        lines = self.lua("query", *map(str, ids))
        self.assertEqual([bytes.fromhex(line[0]) for line in lines], [mdns.service_query(i) for i in ids])

    def test_the_window_takes_a_legacy_answer(self):
        box = mdns.Box(BOX, "HSB2", name="Living Room", port=443)
        rows = self.take(1001, None, mdns.build_answer(DRIVER_QUERY_1001, [box], address=ADDRESS))
        instance = "HueSyncBox-%s._huesync._tcp.local" % BOX
        self.assertEqual(rows, [["row", BOX, BOX, "HSB2", "Living Room", instance, ADDRESS, "443", "a"]])

    def test_the_window_takes_several_boxes_and_another_port(self):
        boxes = [mdns.Box(BOX, "HSB2", port=8443), mdns.Box(OTHER_BOX, "HSB1", name="Bar", address=OTHER_ADDRESS)]
        together = mdns.build_answer(DRIVER_QUERY_1001, boxes, address=ADDRESS)
        rows = self.take(1001, None, together)
        self.assertEqual(
            [(r[1], r[3], r[6], r[7]) for r in rows],
            [(BOX, "HSB2", ADDRESS, "8443"), (OTHER_BOX, "HSB1", OTHER_ADDRESS, "443")],
        )
        apart = [mdns.build_answer(DRIVER_QUERY_1001, [b], address=ADDRESS) for b in boxes]
        self.assertEqual(self.take(1001, None, *apart), rows)

    def test_the_sender_counts_on_os_4(self):
        box = mdns.Box(BOX, address=ADDRESS)
        rows = self.take(1001, OTHER_ADDRESS, mdns.build_answer(DRIVER_QUERY_1001, [box]))
        self.assertEqual([(r[6], r[8]) for r in rows], [(ADDRESS, "a"), (OTHER_ADDRESS, "from")])

    def test_the_window_refuses_what_the_fake_must_not_send(self):
        box = mdns.Box(BOX, address=ADDRESS)
        # The mDNS form (id 0), which is why a legacy query must get the legacy answer.
        multicast = mdns.build_answer(DRIVER_QUERY_1001, [box], legacy=False)
        rows = self.take(1001, None, multicast)
        self.assertEqual(rows[0][0], "refused")
        self.assertIn("id 0x0000", rows[0][1])
        # An answer to another query.
        other = mdns.build_answer(mdns.service_query(1002), [box])
        self.assertEqual(self.take(1001, None, other)[0][0], "refused")

    def test_a_whole_search_lists_the_fake_box(self):
        # The release driver's search: its query goes through `mdns.py answer`, the answers come back
        # through ReceivedFromNetwork, and the identity check at the address (what the fake's GET
        # /api/v1/device answers) reports the same id. Port 443: a release build takes no other.
        identities = "%s=%s/HSB2/Living Room" % (ADDRESS, BOX)
        args = ["--box", "HSB2:%s:443:Living Room" % BOX, "--address", ADDRESS]
        lines = self.lua("search", sys.executable, SCRIPT, identities, *args)
        queries = [bytes.fromhex(line[1]) for line in lines if line[0] == "query"]
        self.assertEqual(len(queries), 2, lines)  # the query and its repeat
        self.assertEqual(queries[0][2:], DRIVER_QUERY_1001[2:])  # the same question, its own id
        self.assertEqual(
            [line for line in lines if line[0] != "query"],
            [["text", "1 Hue sync box found"], ["box", BOX, "Living Room", "HSB2", ADDRESS]],
        )

    def test_a_search_drops_a_box_whose_identity_differs(self):
        identities = "%s=%s/HSB2/Other" % (ADDRESS, OTHER_BOX)
        lines = self.lua("search", sys.executable, SCRIPT, identities, "--box", "HSB2:" + BOX, "--address", ADDRESS)
        self.assertIn(["text", "no answer led to a Hue sync box"], lines)
        dropped = [line for line in lines if line[0] == "dropped"]
        self.assertEqual(len(dropped), 1, lines)
        self.assertIn("but box %s answers there" % OTHER_BOX, dropped[0][2])


# The network --------------------------------------------------------------------------------------------


class Recording(mdns.Responder):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.seen_ids = []

    def handle(self, data, source):
        if len(data) >= 2:
            self.seen_ids.append(struct.unpack_from("!H", data, 0)[0])
        return super().handle(data, source)


class LiveTest(unittest.TestCase):
    """The responder on the real 224.0.0.251:5353, shared with avahi, and a legacy unicast query to it."""

    def test_a_real_legacy_unicast_query_is_answered_from_5353(self):
        interface = mdns.default_address()
        if interface is None:
            self.skipTest("no route to %s on this host" % mdns.GROUP)
        name = "fakebox-test-" + secrets.token_hex(4)
        responder = Recording([mdns.Box(BOX, "HSB2", name=name, port=8443)], interface=interface)
        try:
            responder.start()
        except OSError as error:
            self.skipTest("port 5353 cannot be shared here: %s" % error)
        self.addCleanup(responder.stop)
        query_id = secrets.randbelow(65535) + 1
        got = mdns.query(mdns.service_query(query_id), timeout=1.5, interface=interface)
        ours = [(data, source) for data, source in got if name.encode() in data]
        if not ours and query_id not in responder.seen_ids:
            self.skipTest("multicast does not loop back to this host's own sockets")
        self.assertEqual(len(ours), 1, got)
        data, source = ours[0]
        self.assertEqual(source, (interface, mdns.PORT))
        decoded = decode(data)
        self.assertEqual(decoded["id"], query_id)
        self.assertEqual(by_type(decoded, mdns.TYPE_SRV)[0]["data"][2], 8443)
        self.assertEqual(by_type(decoded, mdns.TYPE_A)[0]["data"], interface)
        self.assertGreaterEqual(responder.answers, 1)
        responder.stop()
        self.assertIsNone(responder._thread)


if __name__ == "__main__":
    unittest.main()
