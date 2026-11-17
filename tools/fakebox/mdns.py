#!/usr/bin/env python3
"""The fake Hue Sync Box's mDNS answer for _huesync._tcp.local (#547, docs/fakebox-design.md §5).

What a box announces (docs/syncbox-api-research.md §2.2): the service _huesync._tcp.local, the
instance HueSyncBox-<box id>, the host <box id>.local, port 443, and TXT name (the friendly name),
devicetype, uniqueid (the 12 upper-case hex digits) and path=/api. The fake announces the same, with
the port of its HTTPS server (8450 by default; a development build's syncbox/devhooks.lua takes a port
other than 443, a release build does not, §7) and the IPv4 address the server listens on.

How the drivers ask (src/common/mdns.lua, src/hue_syncbox/syncbox/discovery.lua): one PTR question for
_huesync._tcp.local, class IN, unicast-response bit clear, sent to 224.0.0.251:5353 from the driver's
own port (6008 on the controller), so a legacy unicast query (RFC 6762 §6.7). The answer that counts
(#490): sent by unicast to the query's address and port, the query id repeated and the question with
it; a PTR in the answer section, the instance's SRV, TXT and the host's A record in the additional
section (the shape the house's Bridge Pro gives to the same query for _hue._tcp.local, common/mdns.lua's
header); every name after the first compressed by a pointer back. As RFC 6762 asks of a legacy unicast
answer, its TTLs are at most 10 seconds and no cache-flush bit is set (§6.7, §10.2).

A query from port 5353 (avahi, another mDNS stack) is answered as mDNS does: id 0, no question, the
cache-flush bit on the unique records (SRV, TXT, A), TTLs 120 s for SRV and A and 4500 s for PTR and TXT
(§10), to 224.0.0.251:5353, or to the sender when a question has the unicast-response bit (§5.4).
Questions answered: PTR or ANY for _huesync._tcp.local (and for _services._dns-sd._udp.local, which
names the service, RFC 6763 §9); SRV, TXT or ANY for an instance; A or ANY for a box's host name.
Anything else, a response, or a packet that does not parse gets no answer. Several boxes at once: the
responder sends one datagram per box, as separate boxes would (build_answer takes any number).

The responder's socket is bound to 224.0.0.251:5353 itself with SO_REUSEADDR (and SO_REUSEPORT where
there is one), so it shares the port with avahi and never takes a unicast datagram meant for avahi; on
Linux a socket bound to a multicast address sends from the interface's own address, so every answer
leaves from port 5353. It joins the group (IP_ADD_MEMBERSHIP) on the chosen interface.

Standard library only, python3 -I safe (imports nothing of tools/), no state outside the process.

API:
  Box(box_id, model="HSB2", name="Hue Sync Box", port=443, address=None, path="/api")
  build_answer(query_bytes, boxes, *, legacy=True, address=None) -> bytes | None
      the answer to one query (pure); `legacy`: the query came from a port other than 5353;
      `address`: the A record of a box without its own
  service_query(query_id, service=SERVICE) -> bytes   the drivers' question, byte for byte
  Responder(boxes, *, address=None, interface=None, separate=True, log=None, group=GROUP, port=PORT)
      .handle(data, source) -> [(packet, destination)]   the datagrams to send for one received
      .start() / .stop() / with Responder(...) as r      the socket and its thread
      .set_boxes(boxes); .queries (datagrams received); .answers (datagrams sent)
  query(packet, *, timeout=2.0, interface=None) -> [(data, (ip, port))]
      send one legacy unicast query to the group from an ephemeral port; every datagram back
  default_address() -> the source address of this host's route to 224.0.0.251, or None

CLI:
  python3 -I tools/fakebox/mdns.py serve --box MODEL:ID[:PORT[:NAME]]... [--address A] [--interface I]
  python3 -I tools/fakebox/mdns.py answer --box ... --address A [--multicast] QUERY_HEX
      prints the answer's datagrams in hex, one a line (no network)
  python3 -I tools/fakebox/mdns.py query [--id N] [--service S | --hex QUERY_HEX] [--timeout S]
      prints "<address> <port> <hex>" for every datagram back
"""

import argparse
import dataclasses
import ipaddress
import re
import socket
import struct
import sys
import threading
import time

GROUP = "224.0.0.251"
PORT = 5353
SERVICE = "_huesync._tcp.local"
SERVICES_META = "_services._dns-sd._udp.local"
INSTANCE_PREFIX = "HueSyncBox-"

TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_AAAA, TYPE_SRV, TYPE_ANY = 1, 12, 16, 28, 33, 255
CLASS_IN, CLASS_ANY = 1, 255
CACHE_FLUSH = 0x8000  # in a record's class: the record is unique (RFC 6762 §10.2)
UNICAST_RESPONSE = 0x8000  # in a question's class: the QU bit (RFC 6762 §5.4)
FLAGS_ANSWER = 0x8400  # QR and AA, opcode 0, rcode 0

LEGACY_TTL = 10  # RFC 6762 §6.7
HOST_TTL = 120  # A and SRV (RFC 6762 §10)
OTHER_TTL = 4500  # PTR and TXT

MAX_PACKET = 9000  # RFC 6762 §17, the drivers' MAX_PACKET too
MAX_QUESTIONS = 16  # the drivers' parser refuses more
MAX_JUMPS = 16
MAX_NAME = 255

BOX_ID_RE = re.compile(r"^[0-9A-Fa-f]{12}$")
MODEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")


@dataclasses.dataclass(frozen=True)
class Box:
    """One box as mDNS announces it. box_id is kept upper case; address None means the responder's."""

    box_id: str
    model: str = "HSB2"
    name: str = "Hue Sync Box"
    port: int = 443
    address: str | None = None
    path: str = "/api"

    def __post_init__(self):
        if not isinstance(self.box_id, str) or not BOX_ID_RE.match(self.box_id):
            raise ValueError("a box id is 12 hex digits, not %r" % (self.box_id,))
        object.__setattr__(self, "box_id", self.box_id.upper())
        if not isinstance(self.model, str) or not MODEL_RE.match(self.model):
            raise ValueError("a model is 1 to 32 letters, digits, '_' or '-', not %r" % (self.model,))
        if not isinstance(self.port, int) or isinstance(self.port, bool) or not 1 <= self.port <= 65535:
            raise ValueError("a port is 1 to 65535, not %r" % (self.port,))
        if self.address is not None:
            object.__setattr__(self, "address", _ipv4(self.address))
        for key, value in (("name", self.name), ("path", self.path)):
            if not isinstance(value, str) or not value or len((key + "=" + value).encode("utf-8")) > 255:
                raise ValueError("a TXT %s is 1 to %d bytes, not %r" % (key, 254 - len(key), value))

    @property
    def instance(self):
        return INSTANCE_PREFIX + self.box_id

    @property
    def instance_name(self):
        return self.instance + "." + SERVICE

    @property
    def host(self):
        return self.box_id + ".local"

    def txt(self):
        """The TXT strings: name, devicetype, uniqueid and path (docs/syncbox-api-research.md §2.2)."""
        pairs = (("name", self.name), ("devicetype", self.model), ("uniqueid", self.box_id), ("path", self.path))
        return [("%s=%s" % pair).encode("utf-8") for pair in pairs]


def _ipv4(text):
    try:
        return str(ipaddress.IPv4Address(text))
    except (ipaddress.AddressValueError, ValueError, TypeError) as error:
        raise ValueError("not an IPv4 address: %r" % (text,)) from error


# Reading a query -----------------------------------------------------------------------------------


class _Malformed(Exception):
    pass


def _read_name(data, at):
    """The name at byte `at` (labels joined by ".", case kept) and the offset just after it."""
    labels, jumps, resume, length, pos = [], 0, None, 0, at
    while True:
        if pos >= len(data):
            raise _Malformed("a name runs past the packet")
        size = data[pos]
        if size == 0:
            pos += 1
            break
        if size >= 0xC0:
            if pos + 1 >= len(data):
                raise _Malformed("a pointer runs past the packet")
            target = ((size & 0x3F) << 8) | data[pos + 1]
            if target >= pos:
                raise _Malformed("a pointer that does not point back")
            jumps += 1
            if jumps > MAX_JUMPS:
                raise _Malformed("too many pointers")
            if resume is None:
                resume = pos + 2
            pos = target
        elif size >= 0x40:
            raise _Malformed("a label length of %d" % size)
        else:
            if pos + 1 + size > len(data):
                raise _Malformed("a label runs past the packet")
            length += size + 1
            if length > MAX_NAME:
                raise _Malformed("a name longer than 255 bytes")
            labels.append(data[pos + 1 : pos + 1 + size])
            pos += 1 + size
    return tuple(labels), resume if resume is not None else pos


def _labels(name):
    """A name's labels as bytes: a text name split at its dots, or labels as read from a packet."""
    if isinstance(name, str):
        return tuple(label.encode("utf-8") for label in name.split(".") if label)
    return tuple(name)


def _key(name):
    """What two names are compared by: their labels, ASCII letters in lower case (RFC 1035 §2.3.3)."""
    return tuple(label.lower() for label in _labels(name))


@dataclasses.dataclass
class _Question:
    labels: tuple  # the name's labels as sent, case kept, so they are repeated byte for byte
    qtype: int
    qclass: int  # with the QU bit

    @property
    def key(self):
        return _key(self.labels)

    @property
    def unicast(self):
        return bool(self.qclass & UNICAST_RESPONSE)


def _parse_query(data):
    """(id, [questions]) of a standard query, or None for anything else (never raises)."""
    if not isinstance(data, (bytes, bytearray, memoryview)):
        return None
    try:
        data = bytes(data)
        if len(data) < 12 or len(data) > MAX_PACKET:
            return None
        qid, flags, qd = struct.unpack_from("!HHH", data, 0)
        if flags & 0x8000 or (flags >> 11) & 0xF != 0 or qd == 0 or qd > MAX_QUESTIONS:
            return None
        pos, questions = 12, []
        for _ in range(qd):
            labels, pos = _read_name(data, pos)
            if pos + 4 > len(data):
                return None
            qtype, qclass = struct.unpack_from("!HH", data, pos)
            pos += 4
            questions.append(_Question(labels, qtype, qclass))
        return qid, questions
    except (_Malformed, struct.error, IndexError):
        return None


# Writing an answer ---------------------------------------------------------------------------------


class _Writer:
    """A DNS message body with name compression: every suffix written once, then pointed to."""

    def __init__(self):
        self.buf = bytearray()
        self.known = {}

    def name(self, name):
        labels = _labels(name)
        for i, raw in enumerate(labels):
            suffix = _key(labels[i:])
            offset = self.known.get(suffix)
            if offset is not None:
                self.buf += struct.pack("!H", 0xC000 | offset)
                return
            if len(self.buf) < 0x3FFF:
                self.known[suffix] = len(self.buf)
            if not 0 < len(raw) < 64:
                raise ValueError("a label of %d bytes" % len(raw))
            self.buf.append(len(raw))
            self.buf += raw
        self.buf.append(0)

    def record(self, rec, ttl, cache_flush):
        name, rtype, rdata = rec
        self.name(name)
        rclass = CLASS_IN | (CACHE_FLUSH if cache_flush and rtype != TYPE_PTR else 0)
        self.buf += struct.pack("!HHI", rtype, rclass, ttl)
        slot = len(self.buf)
        self.buf += b"\0\0"
        if rtype == TYPE_PTR:
            self.name(rdata)
        elif rtype == TYPE_SRV:
            port, target = rdata
            self.buf += struct.pack("!HHH", 0, 0, port)
            self.name(target)
        elif rtype == TYPE_TXT:
            for item in rdata:
                self.buf.append(len(item))
                self.buf += item
        elif rtype == TYPE_A:
            self.buf += socket.inet_aton(rdata)
        struct.pack_into("!H", self.buf, slot, len(self.buf) - slot - 2)


def _ttl(rtype, legacy):
    ttl = HOST_TTL if rtype in (TYPE_A, TYPE_SRV) else OTHER_TTL
    return min(ttl, LEGACY_TTL) if legacy else ttl


def _records(questions, boxes, address):
    """(answers, additionals), each a list of (name, type, data) without repeats."""
    answers, additionals = [], []

    def add(section, rec):
        if rec not in answers and rec not in section:
            section.append(rec)

    def box_address(box):
        ip = box.address or address
        if ip is None:
            raise ValueError("box %s has no address and no default address was given" % box.box_id)
        return ip

    def srv(box):
        return (box.instance_name, TYPE_SRV, (box.port, box.host))

    def txt(box):
        return (box.instance_name, TYPE_TXT, tuple(box.txt()))

    def a(box):
        return (box.host, TYPE_A, box_address(box))

    for q in questions:
        any_type = q.qtype == TYPE_ANY
        if (q.qclass & 0x7FFF) not in (CLASS_IN, CLASS_ANY):
            continue
        if q.key == _key(SERVICE) and (q.qtype == TYPE_PTR or any_type):
            for box in boxes:
                add(answers, (SERVICE, TYPE_PTR, box.instance_name))
        elif q.key == _key(SERVICES_META) and (q.qtype == TYPE_PTR or any_type) and boxes:
            add(answers, (SERVICES_META, TYPE_PTR, SERVICE))
        else:
            for box in boxes:
                if q.key == _key(box.instance_name):
                    if q.qtype == TYPE_SRV or any_type:
                        add(answers, srv(box))
                    if q.qtype == TYPE_TXT or any_type:
                        add(answers, txt(box))
                elif q.key == _key(box.host) and (q.qtype == TYPE_A or any_type):
                    add(answers, a(box))
    # What a querier needs next (RFC 6763 §12): SRV and TXT of each instance named, A of each host.
    for name, rtype, data in list(answers):
        for box in boxes:
            if rtype == TYPE_PTR and name == SERVICE and data == box.instance_name:
                add(additionals, srv(box))
                add(additionals, txt(box))
                add(additionals, a(box))
            elif rtype == TYPE_SRV and name == box.instance_name:
                add(additionals, a(box))
    # The A records last, after the SRV and TXT records of every box.
    additionals.sort(key=lambda rec: rec[1] == TYPE_A)
    return answers, additionals


def build_answer(query_bytes, boxes, *, legacy=True, address=None):
    """The answer to one query for these boxes, or None when it asks nothing they answer or is not a
    query. legacy=True (the query came from a port other than 5353, as the drivers' does): the id and
    the questions repeated, TTLs at most 10 s, no cache-flush bit. legacy=False: an mDNS response (id 0,
    no question, cache-flush on SRV, TXT and A). `address`: the A record of a box with none of its own.
    Raises ValueError only for a box without any address; never for the packet."""
    parsed = _parse_query(query_bytes)
    if parsed is None:
        return None
    qid, questions = parsed
    boxes = list(boxes)
    answers, additionals = _records(questions, boxes, address)
    if not answers:
        return None
    w = _Writer()
    w.buf += struct.pack(
        "!HHHHHH",
        qid if legacy else 0,
        FLAGS_ANSWER,
        len(questions) if legacy else 0,
        len(answers),
        0,
        len(additionals),
    )
    if legacy:
        for q in questions:
            w.name(q.labels)
            w.buf += struct.pack("!HH", q.qtype, q.qclass)
    for rec in answers:
        w.record(rec, _ttl(rec[1], legacy), not legacy)
    for rec in additionals:
        w.record(rec, _ttl(rec[1], legacy), not legacy)
    return bytes(w.buf)


def service_query(query_id, service=SERVICE):
    """The question the drivers send (common/mdns.lua query): id, one PTR question, class IN."""
    w = _Writer()
    w.buf += struct.pack("!HHHHHH", int(query_id) % 65536, 0, 1, 0, 0, 0)
    w.name(service)
    w.buf += struct.pack("!HH", TYPE_PTR, CLASS_IN)
    return bytes(w.buf)


# The network ---------------------------------------------------------------------------------------


def default_address():
    """The source address of this host's route to the mDNS group (no packet is sent), or None."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect((GROUP, PORT))
            address = probe.getsockname()[0]
    except OSError:
        return None
    if not address or address == "0.0.0.0" or address.startswith("127."):
        return None
    return address


def _multicast_options(sock, interface):
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_LOOP, 1)
    if interface:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(interface))


class Responder:
    """Answers _huesync._tcp.local queries for `boxes` (see the module's text)."""

    def __init__(self, boxes=(), *, address=None, interface=None, separate=True, log=None, group=GROUP, port=PORT):
        self.address = _ipv4(address) if address else None
        self.interface = _ipv4(interface) if interface else None
        self.separate = separate
        self.log = log
        self.group, self.port = group, port
        self._lock = threading.Lock()
        self._boxes = ()
        self.set_boxes(boxes)
        self.queries = 0
        self.answers = 0
        self._sock = None
        self._thread = None
        self._stop = threading.Event()

    @property
    def boxes(self):
        with self._lock:
            return self._boxes

    def set_boxes(self, boxes):
        """Replace the boxes announced (a rename, an address or port change, a box added or gone)."""
        boxes = tuple(boxes)
        for box in boxes:
            if not isinstance(box, Box):
                raise TypeError("not a Box: %r" % (box,))
        with self._lock:
            self._boxes = boxes

    def handle(self, data, source):
        """The datagrams to send for one received from `source` (address, port): [(packet, dest)]."""
        parsed = _parse_query(data)
        if parsed is None:
            return []
        _, questions = parsed
        legacy = source[1] != PORT
        dest = tuple(source[:2]) if legacy or any(q.unicast for q in questions) else (self.group, self.port)
        boxes = self.boxes
        groups = [[box] for box in boxes] if self.separate else [list(boxes)]
        out = []
        for group in groups:
            packet = build_answer(data, group, legacy=legacy, address=self.address)
            if packet is not None:
                out.append((packet, dest))
        return out

    def start(self):
        """Bind 224.0.0.251:5353 (shared), join the group, answer in a daemon thread. OSError when the
        port cannot be shared (a holder without SO_REUSEADDR) or the group cannot be joined."""
        if self._thread is not None:
            return self
        interface = self.interface or default_address()
        if self.address is None:
            self.address = interface
        if self.address is None and any(box.address is None for box in self.boxes):
            raise ValueError("no address for the A record: give one (this host has no route to %s)" % self.group)
        interface = interface or "0.0.0.0"
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if hasattr(socket, "SO_REUSEPORT"):
                try:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
                except OSError:
                    pass
            _multicast_options(sock, interface if interface != "0.0.0.0" else None)
            sock.bind((self.group, self.port))
            mreq = struct.pack("4s4s", socket.inet_aton(self.group), socket.inet_aton(interface))
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
            sock.settimeout(0.2)
        except OSError:
            sock.close()
            raise
        self._sock = sock
        self._stop.clear()
        self._thread = threading.Thread(target=self._serve, name="fakebox-mdns", daemon=True)
        self._thread.start()
        self._say("mdns: answering %s on %s:%d (interface %s)", SERVICE, self.group, self.port, interface)
        return self

    def stop(self):
        thread, sock = self._thread, self._sock
        if thread is None:
            return
        self._stop.set()
        thread.join(timeout=5)
        sock.close()
        self._thread = self._sock = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    def _say(self, text, *args):
        if self.log:
            self.log(text % args)

    def _serve(self):
        sock = self._sock
        while not self._stop.is_set():
            try:
                data, source = sock.recvfrom(MAX_PACKET + 1)
            except TimeoutError:
                continue
            except OSError as error:
                if self._stop.is_set():
                    break
                self._say("mdns: receive failed: %s", error)
                time.sleep(0.2)
                continue
            self.queries += 1
            try:
                replies = self.handle(data, source)
            except ValueError as error:
                self._say("mdns: no answer: %s", error)
                continue
            for packet, dest in replies:
                try:
                    sock.sendto(packet, dest)
                    self.answers += 1
                    self._say("mdns: %d bytes to %s:%d", len(packet), dest[0], dest[1])
                except OSError as error:
                    self._say("mdns: send to %s:%d failed: %s", dest[0], dest[1], error)


def query(packet, *, timeout=2.0, interface=None, group=GROUP, port=PORT):
    """Send `packet` to the group from an ephemeral port (a legacy unicast query) and collect every
    datagram that comes back within `timeout` seconds: [(data, (address, port))]."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as sock:
        _multicast_options(sock, interface)
        sock.bind(("0.0.0.0", 0))
        sock.sendto(packet, (group, port))
        out, deadline = [], time.monotonic() + timeout
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                return out
            sock.settimeout(left)
            try:
                data, source = sock.recvfrom(MAX_PACKET + 1)
            except TimeoutError:
                return out
            out.append((data, source[:2]))


# The command line ----------------------------------------------------------------------------------


def parse_box(text, port=None):
    """MODEL:ID[:PORT[:NAME]] (the --box of tools/fakebox.py serve, with the port and name added)."""
    parts = text.split(":", 3)
    if len(parts) < 2:
        raise ValueError("a box is MODEL:ID[:PORT[:NAME]], not %r" % text)
    model, box_id = parts[0], parts[1]
    kwargs = {}
    if len(parts) > 2 and parts[2]:
        if not parts[2].isdigit():
            raise ValueError("a port is a number, not %r" % parts[2])
        kwargs["port"] = int(parts[2])
    elif port is not None:
        kwargs["port"] = port
    if len(parts) > 3 and parts[3]:
        kwargs["name"] = parts[3]
    return Box(box_id, model, **kwargs)


def main(argv=None):
    parser = argparse.ArgumentParser(description="The fake Hue Sync Box's mDNS answer for %s." % SERVICE)
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name, text in (("serve", "answer queries until Ctrl-C"), ("answer", "print the answer to one query")):
        p = sub.add_parser(name, help=text)
        p.add_argument("--box", action="append", required=True, help="MODEL:ID[:PORT[:NAME]], repeatable")
        p.add_argument("--port", type=int, help="the SRV port of a box that names none (default 443)")
        p.add_argument("--address", help="the A record (default: this host's address toward the group)")
    serve = sub.choices["serve"]
    serve.add_argument("--interface", help="the IPv4 address of the interface to join the group on")
    answer = sub.choices["answer"]
    answer.add_argument("--multicast", action="store_true", help="answer as to a query from port 5353")
    answer.add_argument("query_hex", help="the query, in hex")
    q = sub.add_parser("query", help="send one legacy unicast query; print what comes back")
    q.add_argument("--id", type=int, default=1, help="the query id (default 1)")
    q.add_argument("--service", default=SERVICE)
    q.add_argument("--hex", help="send these bytes instead of the drivers' question")
    q.add_argument("--timeout", type=float, default=2.0)
    q.add_argument("--interface", help="the IPv4 address of the interface to send on")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "query":
            packet = bytes.fromhex(args.hex) if args.hex else service_query(args.id, args.service)
            for data, (ip, port) in query(packet, timeout=args.timeout, interface=args.interface):
                print("%s %d %s" % (ip, port, data.hex()))
            return 0
        boxes = [parse_box(text, args.port) for text in args.box]
        if args.cmd == "answer":
            address = args.address or default_address()
            data = bytes.fromhex(args.query_hex)
            for box in boxes:
                packet = build_answer(data, [box], legacy=not args.multicast, address=address)
                if packet is not None:
                    print(packet.hex())
            return 0
        responder = Responder(
            boxes, address=args.address, interface=args.interface, log=lambda line: print(line, flush=True)
        )
        with responder:
            for box in responder.boxes:
                print(
                    "mdns: %s %s at %s:%d" % (box.model, box.box_id, box.address or responder.address, box.port),
                    flush=True,
                )
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        return 0
    except (ValueError, OSError) as error:
        print("mdns.py: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
