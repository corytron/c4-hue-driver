#!/usr/bin/env python3
"""Receive files from the Windows session over plain HTTP (PUT), for screenshots.

    python3 -I tools/collect.py --dir build/collect [--port 8090]

PUT /img/<name>.png with the file as the body saves it as <dir>/img/<name>.png;
GET /  lists what has arrived. Names are reduced to [A-Za-z0-9._-], one path
segment under the given sub-folder, so nothing can escape --dir. LAN use for a
session only; stop it when the round is over (docs/documentation-plan.md).
"""

import argparse
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SAFE = re.compile(r"[^A-Za-z0-9._-]")


class Handler(BaseHTTPRequestHandler):
    root = "."

    def _target(self):
        parts = [p for p in self.path.split("?")[0].split("/") if p]
        if len(parts) != 2:
            return None
        folder, name = (SAFE.sub("_", p) for p in parts)
        if not name or name.startswith("."):
            return None
        return os.path.join(self.root, folder, name)

    def do_PUT(self):
        target = self._target()
        if not target:
            self.send_error(400, "use PUT /<folder>/<name>")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > 50 * 1024 * 1024:
            self.send_error(411, "Content-Length required (max 50 MB)")
            return
        data = self.rfile.read(length)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as f:
            f.write(data)
        print("saved %s (%d bytes)" % (target, len(data)), flush=True)
        body = ("saved %s %d\n" % (os.path.basename(target), len(data))).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        lines = []
        for folder, _, files in os.walk(self.root):
            for name in sorted(files):
                path = os.path.join(folder, name)
                lines.append("%s %d" % (os.path.relpath(path, self.root), os.path.getsize(path)))
        body = ("\n".join(lines) + "\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", required=True)
    ap.add_argument("--port", type=int, default=8090)
    args = ap.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    Handler.root = os.path.abspath(args.dir)
    print("collecting into %s on port %d" % (Handler.root, args.port), flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
