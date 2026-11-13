#!/usr/bin/env python3
"""Serve the named .c4z packages to the Windows Composer session for one out-of-band install.

An install that does not come from a GitHub release (a `tools/build.sh --dev` build for the dev
loop, a feature-branch build for a hardware test, the dev build docs/release-checklist.md asks for
after a controller OS upgrade) reaches the Windows VM through this server, and only through it
(security review 2026-11-13, I-1; docs/security-fixes-2026-11-design.md, #481). It:

  - copies only the packages named on the command line into a fresh temporary folder (0700), under
    a random 32-hex path segment, so nothing else on the VM is reachable and the URLs cannot be
    guessed: a dev package carries the dev key, and serving build/release/ whole offered every dev
    package ever copied there to the whole LAN;
  - serves exactly those files at http://<address>:<port>/<segment>/<name>, GET and HEAD only, and
    answers 404 to every other path: no directory listing, no index;
  - binds this VM's LAN address (0.0.0.0 only when --bind says so);
  - prints, for the brief, each package's URL, sha256, <version> and whether it is a dev build
    (whose devices show Driver Version "<build>-dev"), and the PowerShell that downloads and
    checks them;
  - stops once every package has been downloaded in full (unless --keep-serving), after --timeout
    seconds (default 1800), or on Ctrl-C or SIGTERM, then deletes the temporary folder.

After the install, record it with `python3 tools/deploy.py record ... --no-manifest` (a dev build is
never the release, so the drift issue stays open until a release is installed again).

Usage: tools/serve_install.py [--port 8090] [--bind ADDRESS] [--timeout SECONDS] [--keep-serving]
                              [--label NAME] PACKAGE.c4z...

JOBS (environment) caps how many packages are copied and hashed at once (default: nproc); the
server answers each download in its own thread. Standard library only.
"""

import argparse
import concurrent.futures
import hashlib
import os
import re
import secrets
import shutil
import signal
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)  # also under python3 -I, which leaves the script's directory out

import devserver  # noqa: E402  (lan_address, url_host, clean: the dev server's own)

DEFAULT_PORT = 8090
DEFAULT_TIMEOUT_S = 1800
# A package name, as tools/deploy.py takes it: <driver>.c4z, usable in a URL and in PowerShell.
PACKAGE_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_-]*\.c4z")
LABEL_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*")
CHUNK = 1 << 16


class ServeError(Exception):
    """A user-facing error: printed to stderr, exit 1."""


def jobs():
    """How many packages are copied and hashed at once: JOBS, else every core."""
    text = os.environ.get("JOBS")
    if text:
        if not re.fullmatch(r"[1-9][0-9]*", text):
            raise ServeError("JOBS must be a whole number from 1, not %r" % text)
        return int(text)
    return os.cpu_count() or 1


def check_packages(paths):
    """The packages to serve, as [(name, source path)]; a ServeError naming every problem."""
    if not paths:
        raise ServeError("name at least one .c4z package to serve")
    problems = []
    seen = {}
    for path in paths:
        name = os.path.basename(path)
        if not PACKAGE_RE.fullmatch(name):
            problems.append("%s: only <driver>.c4z packages are served" % path)
        elif not os.path.isfile(path):
            problems.append("%s: no such file" % path)
        elif name in seen:
            problems.append("%s and %s: two packages named %s" % (seen[name], path, name))
        else:
            seen[name] = path
    if problems:
        raise ServeError("\n  ".join(["cannot serve:"] + problems))
    return sorted(seen.items())


def describe(path):
    """(version, dev) of a package: its driver.xml <version> (None when unreadable) and whether
    it is a dev build (common/build_kind.lua says "dev", or it carries common/devkey.lua)."""
    try:
        with zipfile.ZipFile(path) as package:
            names = set(package.namelist())
            version = None
            if "driver.xml" in names:
                text = package.read("driver.xml").decode("utf-8", "replace")
                version = (ET.fromstring(text).findtext("version") or "").strip() or None
            kind = ""
            if "common/build_kind.lua" in names:
                kind = package.read("common/build_kind.lua").decode("utf-8", "replace")
            dev = '"dev"' in kind or "common/devkey.lua" in names
            return version, dev
    except (zipfile.BadZipFile, ET.ParseError, KeyError, OSError) as err:
        raise ServeError("%s is not a readable .c4z package: %s" % (path, err)) from err


def copy_one(source, folder, name):
    """Copy one package into the served folder (0600) and hash the copy, which is what is served."""
    target = os.path.join(folder, name)
    digest = hashlib.sha256()
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with open(source, "rb") as src, os.fdopen(fd, "wb") as dst:
        for chunk in iter(lambda: src.read(CHUNK), b""):
            digest.update(chunk)
            dst.write(chunk)
    version, dev = describe(target)
    return {
        "name": name,
        "path": target,
        "sha256": digest.hexdigest(),
        "bytes": os.path.getsize(target),
        "version": version,
        "dev": dev,
    }


def stage(packages, max_workers=1):
    """A fresh temporary folder (0700) holding a random 32-hex segment holding copies of the
    packages and nothing else. Returns (root, segment, [entry]) in the order of packages."""
    root = tempfile.mkdtemp(prefix="c4-hue-install-")
    try:
        segment = secrets.token_hex(16)
        folder = os.path.join(root, segment)
        os.mkdir(folder, 0o700)
        workers = max(1, min(max_workers, len(packages)))
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            entries = list(pool.map(lambda item: copy_one(item[1], folder, item[0]), packages))
        return root, segment, entries
    except BaseException:
        shutil.rmtree(root, ignore_errors=True)
        raise


class InstallHandler(BaseHTTPRequestHandler):
    """GET and HEAD of exactly /<segment>/<name> for a staged package; 404 for everything else."""

    server_version = "c4-hue-install/1"
    sys_version = ""
    protocol_version = "HTTP/1.1"
    timeout = 60

    def log_message(self, fmt, *args):
        """Quiet the default access log; requests are logged in answer()."""

    def do_GET(self):
        self.answer(body=True)

    def do_HEAD(self):
        self.answer(body=False)

    def answer(self, body):
        entry = self.server.files.get(urlsplit(self.path).path)
        if entry is None:
            self.server.note("%s %s %s -> 404" % (self.client_address[0], self.command, self.path))
            payload = b"not found\n"
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if body:
                self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(entry["bytes"]))
        self.send_header("Content-Disposition", 'attachment; filename="%s"' % entry["name"])
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if not body:
            self.server.note("%s HEAD %s -> 200" % (self.client_address[0], entry["name"]))
            return
        sent = 0
        with open(entry["path"], "rb") as handle:
            for chunk in iter(lambda: handle.read(CHUNK), b""):
                self.wfile.write(chunk)
                sent += len(chunk)
        self.wfile.flush()
        self.server.note("%s GET %s -> 200, %d bytes" % (self.client_address[0], entry["name"], sent))
        self.server.fetched(entry["name"])


class InstallServer(ThreadingHTTPServer):
    """The listener: the staged files by URL path, and when to stop."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, segment, entries, until_fetched=True, out=None):
        super().__init__(address, InstallHandler)
        self.files = {"/%s/%s" % (segment, entry["name"]): entry for entry in entries}
        self.until_fetched = until_fetched
        self.out = out or sys.stdout
        self.lock = threading.Lock()
        self.downloads = {entry["name"]: 0 for entry in entries}
        self.done = threading.Event()

    def note(self, text):
        with self.lock:
            self.out.write("%s %s\n" % (time.strftime("%H:%M:%S"), devserver.clean(text)))
            self.out.flush()

    def fetched(self, name):
        """One full download of `name`; once every package has one, the server stops (until_fetched)."""
        with self.lock:
            self.downloads[name] += 1
            complete = all(self.downloads.values())
        if complete and self.until_fetched and not self.done.is_set():
            self.done.set()
            self.note("every package has been downloaded once: stopping")
            threading.Thread(target=self.shutdown, daemon=True).start()

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        self.note("%s: %s: %s" % (client_address[0], exc.__class__.__name__, exc))


def brief_text(base_url, entries, label):
    """What the brief to the Windows session carries: URLs, hashes and the PowerShell that checks them."""
    folder = "C:\\c4-hue\\drivers\\%s" % label
    lines = ["| File | Version | sha256 | URL |", "| --- | --- | --- | --- |"]
    for entry in entries:
        version = entry["version"] or "?"
        if entry["dev"]:
            version += " (dev build: Driver Version reads %s-dev)" % version
        lines.append("| %s | %s | `%s` | %s%s |" % (entry["name"], version, entry["sha256"], base_url, entry["name"]))
    lines += ["", "```powershell", "$dir = '%s'" % folder, "New-Item -ItemType Directory -Force -Path $dir | Out-Null"]
    for entry in entries:
        lines.append(
            "Invoke-WebRequest -UseBasicParsing -Uri '%s%s' -OutFile \"$dir\\%s\""
            % (base_url, entry["name"], entry["name"])
        )
    lines.append("$expected = @{")
    for entry in entries:
        lines.append("    '%s' = '%s'" % (entry["name"], entry["sha256"]))
    lines += [
        "}",
        "foreach ($name in $expected.Keys) {",
        '    $hash = (Get-FileHash "$dir\\$name" -Algorithm SHA256).Hash.ToLower()',
        '    if ($hash -ne $expected[$name]) { throw "sha256 mismatch for $name: $hash" }',
        '    "$name OK $hash"',
        "}",
        "```",
        "",
        "A hash that differs ends the round: report it and install nothing.",
    ]
    return "\n".join(lines) + "\n"


def default_label(entries):
    versions = sorted({entry["version"] for entry in entries if entry["version"]})
    kind = "dev" if any(entry["dev"] for entry in entries) else "build"
    return "%s-%s" % (kind, versions[0] if len(versions) == 1 else "mixed")


def build_parser():
    parser = argparse.ArgumentParser(
        description="Serve .c4z packages for one out-of-band install (docs/dev-loop.md, Deploy in CLAUDE.md)."
    )
    parser.add_argument("packages", nargs="+", metavar="PACKAGE.c4z", help="the packages to serve, nothing else")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="port (default %d)" % DEFAULT_PORT)
    parser.add_argument(
        "--bind", default=None, help="address to listen on (default: this VM's LAN address; 0.0.0.0 only when given)"
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_S,
        help="stop after this many seconds whatever happened (default %d; 0: no limit)" % DEFAULT_TIMEOUT_S,
    )
    parser.add_argument(
        "--keep-serving",
        action="store_true",
        help="keep serving after every package has been downloaded once (until the timeout or Ctrl-C)",
    )
    parser.add_argument(
        "--label", default=None, help="the folder name on the Windows VM (default dev-<version> or build-<version>)"
    )
    return parser


def main(argv=None, out=None):
    out = out or sys.stdout
    args = build_parser().parse_args(argv)
    root = None
    try:
        if args.label is not None and not LABEL_RE.fullmatch(args.label):
            raise ServeError("--label must be letters, digits, '.', '_' or '-', not %r" % args.label)
        if args.timeout < 0:
            raise ServeError("--timeout must be 0 (no limit) or more")
        packages = check_packages(args.packages)
        bind = devserver.choose_bind(args.bind)
        if not bind:
            raise ServeError("could not find this VM's LAN address (no default route?); pass --bind <address>")
        root, segment, entries = stage(packages, jobs())
        server = InstallServer((bind, args.port), segment, entries, until_fetched=not args.keep_serving, out=out)
    except ServeError as err:
        if root:
            shutil.rmtree(root, ignore_errors=True)
        print("serve_install: %s" % err, file=sys.stderr)
        return 1
    except OSError as err:
        if root:
            shutil.rmtree(root, ignore_errors=True)
        print("serve_install: %s" % err, file=sys.stderr)
        return 1

    base_url = "http://%s:%d/%s/" % (devserver.url_host(bind), server.server_address[1], segment)
    label = args.label or default_label(entries)
    out.write("serving %d package(s) from %s (deleted when this stops)\n" % (len(entries), root))
    if bind == "0.0.0.0":
        out.write("WARNING listening on every address (--bind 0.0.0.0)\n")
    if any(entry["dev"] for entry in entries):
        out.write("WARNING dev packages carry the dev key: stop this server as soon as the download is done\n")
    stops = ["once every package has been downloaded in full"] if not args.keep_serving else []
    if args.timeout:
        stops.append("after %gs" % args.timeout)
    stops.append("on Ctrl-C")
    out.write("stops %s\n\n" % ", ".join(stops))
    out.write(brief_text(base_url, entries, label))
    out.write("\n")
    out.flush()

    timer = None
    if args.timeout:
        timer = threading.Timer(args.timeout, server.shutdown)
        timer.daemon = True
        timer.start()
    # SIGTERM (pkill) stops it like Ctrl-C, so the folder goes too. Only the main thread may set it.
    previous = None
    if threading.current_thread() is threading.main_thread():
        previous = signal.signal(
            signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start()
        )
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        if previous is not None:
            signal.signal(signal.SIGTERM, previous)
        if timer:
            timer.cancel()
        server.server_close()
        shutil.rmtree(root, ignore_errors=True)
        counts = ", ".join("%s %d" % (name, count) for name, count in sorted(server.downloads.items()))
        out.write("stopped; downloads: %s; deleted %s\n" % (counts, root))
        out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
