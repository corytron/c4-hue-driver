#!/usr/bin/env python3
"""Throwaway HTTPS server for the C4:url connection experiment.

Serves, over TLS with a self-signed certificate:
  /stream   an endless text/event-stream: ": hi" then an event every 2 s
  /ping     a tiny JSON reply
  anything else: 404

Every connection and request is logged with a timestamp, so the log shows
whether the controller ever opened a second connection while a stream was
in progress. Multithreaded: the server itself never limits concurrency.

Usage: tools/diag_server.py [--port 8443] [--cert-dir DIR]
The certificate is generated with openssl on first run.
"""
import argparse
import json
import os
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def log(msg):
    with LOCK:
        sys.stdout.write(time.strftime("%H:%M:%S") + " " + msg + "\n")
        sys.stdout.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        sock = self.connection
        try:
            tls = "%s %s alpn=%s" % (sock.version(), sock.cipher()[0], sock.selected_alpn_protocol())
        except Exception as exc:  # noqa: BLE001
            tls = "tls? %s" % exc
        log("OPEN  %s:%d  %s" % (self.client_address[0], self.client_address[1], tls))

    def finish(self):
        super().finish()
        log("CLOSE %s:%d" % self.client_address)

    def log_message(self, fmt, *args):  # quiet the default access log
        pass

    def do_GET(self):
        log("GET   %s:%d  %s" % (self.client_address[0], self.client_address[1], self.path))
        if self.path.startswith("/ping"):
            body = json.dumps({"ok": True, "t": time.time()}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            n = 0
            try:
                self.chunk(": hi\n\n")
                while True:
                    time.sleep(2)
                    n += 1
                    self.chunk("id: %d\ndata: [{\"n\": %d, \"t\": %.3f}]\n\n" % (n, n, time.time()))
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                log("STREAM ended for %s:%d after %d events" % (self.client_address + (n,)))
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def chunk(self, text):
        data = text.encode()
        self.wfile.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
        self.wfile.flush()


def ensure_cert(cert_dir):
    os.makedirs(cert_dir, exist_ok=True)
    crt, key = os.path.join(cert_dir, "diag.crt"), os.path.join(cert_dir, "diag.key")
    if not (os.path.exists(crt) and os.path.exists(key)):
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30",
            "-subj", "/CN=c4-hue-diag", "-keyout", key, "-out", crt,
        ], check=True, capture_output=True)
        log("generated self-signed certificate in " + cert_dir)
    return crt, key


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--cert-dir", default="build/diag")
    args = parser.parse_args()

    crt, key = ensure_cert(args.cert_dir)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(crt, key)
    ctx.set_alpn_protocols(["http/1.1"])

    server = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    server.daemon_threads = True
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    log("listening on port %d" % args.port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
