#!/usr/bin/env python3
"""A fake Hue Play HDMI Sync Box on this VM, for testing the box driver without a box (#547).

The contract is docs/fakebox-design.md (§2 the model, §5 this tool); the rules the fake keeps are
docs/syncbox-behaviour.md. `serve` runs one or more fake boxes over real HTTPS, each on its own port
with a leaf of the VM's fake CA (tools/fakebox/ca.py, under ~/.config/c4-hue-driver/fakebox/), and a
control API on 127.0.0.1; every other command drives the running fake through that API.

  serve [--box FIXTURE:ID[:PORT]]... [--port 8450] [--bind ADDRESS|lan] [--control-port 8444]
        [--time-scale X] [--registration [ID=]REG=TOKEN]... [--placeholder-tokens] [--mdns]
        [--state-dir DIR] [--cert-base DIR] [--fixtures FILE] [--quiet]
      FIXTURE is a model of tests/fixtures/hue_syncbox.json (HSB1, HSB2, HSB3, HSB3_standalone,
      HSB2_behind_receiver, HSB2_second_output); ID the box id (12 hex digits; placeholders
      0A1B2C3D4E5F and 0A1B2C3D4E60 in anything public); boxes without a port take --port, --port+1,
      ... Default: one HSB2 as 0A1B2C3D4E5F. --bind is 127.0.0.1 unless given ("lan": this VM's LAN
      address, for the controller). --time-scale runs the boxes' clocks faster (the pairing window,
      a restart). Tokens are random unless --placeholder-tokens (the Lua fake's TEST-TOKEN-NOT-REAL);
      --registration pairs a box already. --mdns also answers _huesync._tcp.local (tools/fakebox/mdns.py).
  button [--box ID] [--window S]          the link button held (5 s window unless --window)
  event NAME [--box ID] [KEY=VALUE]...    a model event: cec_active_source input=2, signal input=1
                                          status=linked, tv_standby, usb_power_lost, idle minutes=20,
                                          bridge state=busy, rename name=..., app_deletes
                                          registration=7, firmware version=2.6.0 api_level=15, reboot,
                                          advance ms=1000, address address=... [port=N] (VALUE is JSON
                                          when it parses, else text)
  fault KIND [--box ID] [--count N] [--path P] [--method M] [KEY=VALUE]...
                                          silence [hold_s=], latency ms=, 5xx [status= code=], drop,
                                          truncated, oversized [bytes=], redirect [status= location=],
                                          wrong_cert, other_id [id=], refuse
  fault clear [KIND] [--box ID]           clear the faults (of one kind)
  state [--box ID] [--path DOTTED]        the box's GET /api/v1 document, its status and faults
  set PATH VALUE [--box ID] | set PATH --unset   change the document as the Hue Sync app would
  log [--box ID] [-n 50] [--json]         the last requests (tokens never shown)
  boxes                                   the running boxes
  stop                                    stop the fake

The running fake's control URL and token are in <state-dir>/server.json (mode 0600; default
build/fakebox). Standard library only; runs under python3 -I.
"""

import argparse
import json
import os
import signal
import sys
import threading
import time

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)  # also under python3 -I, which leaves the script's directory out

from fakebox import ca, control, model, server  # noqa: E402  (the package tools/fakebox/)

DEFAULT_BOX = "HSB2:0A1B2C3D4E5F"
DEFAULT_PORT = 8450
DEFAULT_CONTROL_PORT = 8444
DEFAULT_STATE_DIR = os.path.join(ROOT, "build", "fakebox")


def _value(text):
    """A KEY=VALUE value: JSON when it parses (2, true, "x", {...}), else the text itself."""
    try:
        return json.loads(text)
    except ValueError:
        return text


def _pairs(items):
    out = {}
    for item in items or []:
        if "=" not in item:
            raise SystemExit("fakebox.py: %r is not KEY=VALUE" % item)
        key, text = item.split("=", 1)
        out[key] = _value(text)
    return out


def _registrations(items, boxes):
    """--registration [ID=]REG=TOKEN -> {box id: {reg: token}}; without ID, the first box."""
    out = {}
    for item in items or []:
        parts = item.split("=")
        if len(parts) == 2:
            box_id, reg, token = boxes[0], parts[0], parts[1]
        elif len(parts) == 3:
            box_id, reg, token = parts[0].upper(), parts[1], parts[2]
        else:
            raise SystemExit("fakebox.py: --registration is [BOX ID=]REGISTRATION=TOKEN, not %r" % item)
        if not reg.isdigit() or not token:
            raise SystemExit("fakebox.py: a registration id is decimal and its token not empty")
        out.setdefault(box_id, {})[reg] = token
    return out


def _bind(text):
    if text != "lan":
        return text
    from fakebox import mdns

    address = mdns.default_address()
    if not address:
        raise SystemExit("fakebox.py: no LAN address found for --bind lan; give one")
    return address


def cmd_serve(args):
    fixtures = model.load_fixtures(args.fixtures)
    specs = [server.parse_spec(s) for s in (args.box or [DEFAULT_BOX])]
    bind = _bind(args.bind)
    regs = _registrations(args.registration, [box_id for _, box_id, _ in specs])
    say = (lambda text: None) if args.quiet else (lambda text: print(text, flush=True))
    log_file = os.path.join(args.state_dir, "requests.jsonl")
    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    servers = []
    for i, (fixture, box_id, port) in enumerate(specs):
        address = bind if bind not in ("0.0.0.0", "127.0.0.1", "") else None
        box = server.make_box(
            fixture,
            box_id,
            fixtures=fixtures,
            time_scale=args.time_scale,
            address=address,
            registrations=regs.get(box_id),
            token_factory=None if args.placeholder_tokens else server.random_token,
        )
        bs = server.BoxServer(
            box,
            port=port if port is not None else (args.port + i if args.port else 0),
            bind=bind,
            cert_base=args.cert_base,
            log=say,
            log_file=log_file,
        )
        bs.fixture = fixture
        servers.append(bs)
    fleet = server.Fleet(servers)
    stopped = threading.Event()
    responder = None

    def refresh_mdns():
        if responder is not None:
            from fakebox import mdns

            announced = []
            for s in servers:
                name = s.box.name or "Hue Sync Box"
                announced.append(mdns.Box(s.box.box_id, s.box.model or "HSB2", name=name, port=s.port))
            responder.set_boxes(announced)

    controller = control.Controller(fleet, on_change=refresh_mdns, on_stop=stopped.set)
    fleet.start()
    try:
        if args.mdns:
            from fakebox import mdns

            responder = mdns.Responder(address=None if bind in ("0.0.0.0", "127.0.0.1") else bind, log=say)
            refresh_mdns()
            responder.start()
        ctl = control.ControlServer(controller, port=args.control_port).start()
        info = {
            "pid": os.getpid(),
            "control_url": ctl.url,
            "token": ctl.token,
            "started": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "ca": ca.ensure_ca(args.cert_base),
            "boxes": [{"id": s.box.box_id, "model": s.box.model, "fixture": s.fixture, "url": s.url} for s in servers],
        }
        control.write_state(args.state_dir, info)
        for s in servers:
            print("fakebox: %s %s (%s) at %s" % (s.box.box_id, s.box.model, s.fixture, s.url), flush=True)
        print("fakebox: CA %s; control %s; log %s" % (info["ca"], ctl.url, log_file), flush=True)

        def on_signal(signum, frame):
            del signum, frame
            stopped.set()

        signal.signal(signal.SIGINT, on_signal)
        signal.signal(signal.SIGTERM, on_signal)
        while not stopped.wait(0.5):
            pass
        ctl.stop()
    finally:
        fleet.stop()
        if responder is not None:
            responder.stop()
        control.remove_state(args.state_dir, pid=os.getpid())
        print("fakebox: stopped", flush=True)
    return 0


def _client(args):
    return control.Client(args.state_dir)


def _print(answer):
    print(json.dumps(answer, indent=2, sort_keys=True))


def cmd_button(args):
    _print(_client(args).call("POST", "/button", {"box": args.box, "window": args.window}))
    return 0


def cmd_event(args):
    body = {"box": args.box, "name": args.name, "args": _pairs(args.pairs)}
    _print(_client(args).call("POST", "/event", body))
    return 0


def cmd_fault(args):
    client = _client(args)
    if args.kind == "clear":
        kind = args.pairs[0] if args.pairs else None
        _print(client.call("POST", "/clear", {"box": args.box, "kind": kind}))
        return 0
    body = {
        "box": args.box,
        "kind": args.kind,
        "count": args.count,
        "path": args.path,
        "method": args.method,
        "params": _pairs(args.pairs),
    }
    _print(client.call("POST", "/fault", body))
    return 0


def cmd_state(args):
    _print(_client(args).call("GET", "/state", query={"box": args.box, "path": args.path}))
    return 0


def cmd_set(args):
    if args.unset:
        body = {"box": args.box, "path": args.path, "unset": True}
    else:
        if args.value is None:
            raise SystemExit("fakebox.py: set PATH VALUE (or --unset)")
        body = {"box": args.box, "path": args.path, "value": _value(args.value)}
    _print(_client(args).call("POST", "/set", body))
    return 0


def cmd_log(args):
    entries = _client(args).call("GET", "/log", query={"box": args.box, "n": args.n})["entries"]
    for entry in entries:
        if args.json:
            print(json.dumps(entry, sort_keys=True))
            continue
        parts = [entry["time"], entry["box"], entry.get("client") or "-", entry["method"], entry.get("path") or "-"]
        parts += [str(entry.get("status") or "-"), "%sms" % entry.get("ms", 0)]
        if entry.get("keyed"):
            parts.append("auth=%s reg=%s" % (server.REDACTED, entry.get("registration")))
        if entry.get("body") is not None:
            parts.append(json.dumps(entry["body"], separators=(",", ":"), sort_keys=True))
        if entry.get("fault"):
            parts.append("[%s]" % entry["fault"])
        if entry.get("note"):
            parts.append(entry["note"])
        print(" ".join(parts))
    return 0


def cmd_boxes(args):
    _print(_client(args).call("GET", "/boxes"))
    return 0


def cmd_stop(args):
    _print(_client(args).call("POST", "/stop"))
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="fakebox.py", description="A fake Hue Sync Box (docs/fakebox-design.md).")
    parser.add_argument("--state-dir", default=DEFAULT_STATE_DIR, help="where server.json lives (%(default)s)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    serve = sub.add_parser("serve", help="run the fake boxes and the control API")
    serve.add_argument("--box", action="append", help="FIXTURE:ID[:PORT] (repeatable; default %s)" % DEFAULT_BOX)
    serve.add_argument("--port", type=int, default=DEFAULT_PORT, help="the first box's port (%(default)s; 0: any)")
    serve.add_argument("--bind", default="127.0.0.1", help="the boxes' address (%(default)s; 'lan': this VM's)")
    serve.add_argument("--control-port", type=int, default=DEFAULT_CONTROL_PORT, help="on 127.0.0.1 (%(default)s)")
    serve.add_argument("--time-scale", type=float, default=1.0, help="the boxes' clocks run this much faster")
    serve.add_argument("--registration", action="append", help="[BOX ID=]REGISTRATION=TOKEN: paired already")
    serve.add_argument("--placeholder-tokens", action="store_true", help="TEST-TOKEN-NOT-REAL instead of random")
    serve.add_argument("--mdns", action="store_true", help="also answer _huesync._tcp.local queries")
    serve.add_argument("--cert-base", default=None, help="the CA's directory (default %s)" % ca.default_base())
    serve.add_argument("--fixtures", default=None, help="the fixtures JSON (default %s)" % model.FIXTURES_JSON)
    serve.add_argument("--quiet", action="store_true", help="no request lines on stdout")
    serve.set_defaults(func=cmd_serve)

    def with_box(p):
        p.add_argument("--box", default=None, help="the box id (needed when several run)")
        return p

    button = with_box(sub.add_parser("button", help="hold the link button"))
    button.add_argument("--window", type=float, default=None, help="seconds the pairing stays open (5)")
    button.set_defaults(func=cmd_button)

    event = with_box(sub.add_parser("event", help="a model event (%s)" % ", ".join(model.EVENTS)))
    event.add_argument("name", choices=model.EVENTS)
    event.add_argument("pairs", nargs="*", metavar="KEY=VALUE")
    event.set_defaults(func=cmd_event)

    fault = with_box(sub.add_parser("fault", help="a fault (%s), or clear" % ", ".join(server.FAULT_KINDS)))
    fault.add_argument("kind", choices=server.FAULT_KINDS + ("clear",))
    fault.add_argument("pairs", nargs="*", metavar="KEY=VALUE")
    fault.add_argument("--count", type=int, default=None, help="for N requests (connections), not until cleared")
    fault.add_argument("--path", default=None, help="only paths starting with this (after /api/v1)")
    fault.add_argument("--method", default=None, help="only this method")
    fault.set_defaults(func=cmd_fault)

    state = with_box(sub.add_parser("state", help="the box's state, status and faults"))
    state.add_argument("--path", default=None, help="one dotted path (execution.mode)")
    state.set_defaults(func=cmd_state)

    setp = with_box(sub.add_parser("set", help="change a dotted path of the state"))
    setp.add_argument("path")
    setp.add_argument("value", nargs="?", default=None)
    setp.add_argument("--unset", action="store_true", help="remove the path instead")
    setp.set_defaults(func=cmd_set)

    log = with_box(sub.add_parser("log", help="the last requests"))
    log.add_argument("-n", type=int, default=50)
    log.add_argument("--json", action="store_true", help="one JSON object a line")
    log.set_defaults(func=cmd_log)

    boxes = sub.add_parser("boxes", help="the running boxes")
    boxes.set_defaults(func=cmd_boxes)
    stop = sub.add_parser("stop", help="stop the fake")
    stop.set_defaults(func=cmd_stop)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except (control.ControlError, ca.CAError, ValueError, LookupError, OSError) as error:
        print("fakebox.py: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
