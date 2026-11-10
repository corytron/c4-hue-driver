#!/usr/bin/env python3
"""Run luacheck, busted and the Python unit tests on every core, with the output of a serial run.

  parallel.py luacheck [PATH...]   luacheck, one process per Lua file (default: src tests tools)
  parallel.py busted [ROOT...]     busted, one process per spec file (default: tests)
  parallel.py unittest [DIR]       python3 -B -m unittest, one process per test module (default: tools/tests)

Issue #456: none of the three uses more than one core on its own (luacheck's --jobs needs LuaLanes,
which is not installed, and busted and unittest have no such option), and lint and the specs were most
of the wall time of tools/check.sh. This tool splits each run into one process per file, runs up to
JOBS of them at once (the largest files first, so that the longest ones do not start last), and prints
the results in the order of the files, whatever order they finished in.

Each subcommand runs the plain tool, unchanged, from the current directory, so .luacheckrc and .busted
apply as they do to `luacheck src tests tools` and `busted tests`, and both plain commands keep working:

  luacheck  finds the same files luacheck finds (every *.lua under each directory, sorted, in the order
            of the arguments) and prints exactly what one luacheck run prints: each file's report, then
            one Total line. luacheck's report header is a fixed width, so the reports of separate runs
            join without a seam. Exit status as luacheck's: 0 clean, 1 warnings, 2 syntax errors,
            3 a file that could not be read, 4 a critical error (printed once). A .luacheckrc that sets
            include_files makes one serial luacheck run instead, since that option changes which files
            a directory holds.
  busted    finds the spec files busted finds (each *.lua whose name holds "_spec" under each root,
            sorted). Files are the unit, because busted insulates every file from the others (its
            globals and package.loaded) but not the tests of one file from each other: splitting a file
            could pass a test that fails after its neighbours. Prints the full busted output of every
            file with a failure, an error, a pending test or anything else beyond its progress line, in
            file order, then the total in busted's own words ("N successes / F failures / E errors /
            P pending : T seconds", T the wall time). Exit status 1 when anything failed, else 0.
  unittest  runs `python3 -B -m unittest discover -s DIR -p FILE` for each test*.py file in DIR (not
            its subfolders: tools/tests has none), prints the full output of every module that did not
            pass or printed more than its progress line, in file order, then unittest's own summary of
            the whole run (Ran N tests in T, OK or FAILED with the counts). Exit status 1 when anything
            failed, 5 when no test ran (as unittest), else 0.

JOBS (environment): how many processes run at once, a whole number from 1; default the number of
cores this process may use (nproc). JOBS=1 runs one file at a time, for debugging.

Standard library only. Exit 2 on a usage error (an unknown subcommand, a bad JOBS, a tool not installed).
"""

import argparse
import concurrent.futures
import dataclasses
import os
import re
import subprocess
import sys
import time

EXIT_USAGE = 2

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

# luacheck's last line (luacheck/format.lua, the default formatter).
LUACHECK_TOTAL_RE = re.compile(
    r"^Total: (\d+) warnings? / (\d+) errors? in (\d+) files?(?:, couldn't check (\d+) files?)?$"
)
LUACHECK_EXIT = {"ok": 0, "warnings": 1, "errors": 2, "fatals": 3, "critical": 4}
# Files a luacheck process gets at least: starting luacheck costs about what checking a small file does.
LUACHECK_FILES_PER_SHARD = 8

# busted's summary line (busted/outputHandlers/plainTerminal.lua, statusString).
BUSTED_SUMMARY_RE = re.compile(
    r"^(\d+) success(?:es)? / (\d+) failures? / (\d+) errors? / (\d+) pending : [0-9.]+ seconds$", re.M
)
# The progress line busted prints before the summary: one character a test.
BUSTED_PROGRESS_RE = re.compile(r"[-+*.]*")

# unittest's summary (unittest/runner.py, TextTestRunner.run).
UNITTEST_RAN_RE = re.compile(r"^Ran (\d+) tests? in [0-9.]+s$", re.M)
UNITTEST_STATUS_RE = re.compile(r"^(OK|FAILED|NO TESTS RAN)(?: \((.*)\))?$", re.M)
UNITTEST_SEPARATOR = "-" * 70
# The progress line of a module that passed: one character a test (pass, skip, expected failure).
UNITTEST_PROGRESS_RE = re.compile(r"[.sx]*")


class UsageError(Exception):
    """A run that cannot start: printed to stderr, exit 2."""


def job_count(environ=None):
    """JOBS when set (a whole number from 1), else the number of cores this process may run on."""
    environ = os.environ if environ is None else environ
    text = environ.get("JOBS", "")
    if text:
        if not re.fullmatch(r"[1-9][0-9]*", text):
            raise UsageError("JOBS must be a whole number from 1 (JOBS=1 runs serially), not %r" % text)
        return int(text)
    try:
        return max(1, len(os.sched_getaffinity(0)))
    except AttributeError:  # not Linux
        return max(1, os.cpu_count() or 1)


@dataclasses.dataclass
class Result:
    returncode: int
    output: str  # standard output and standard error, interleaved as written


def run_one(command):
    try:
        done = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except FileNotFoundError as err:
        raise UsageError("%s is not installed (not found on PATH)" % command[0]) from err
    return Result(done.returncode, done.stdout.decode("utf-8", "replace"))


def run_all(commands, weights, jobs, runner=run_one):
    """Run every command, at most jobs at once, the heaviest first; their Results in the order given."""
    results = [None] * len(commands)
    order = sorted(range(len(commands)), key=lambda i: (-weights[i], i))
    if jobs <= 1 or len(commands) <= 1:
        for i in order:
            results[i] = runner(commands[i])
        return results
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(jobs, len(commands))) as pool:
        futures = {pool.submit(runner, commands[i]): i for i in order}
        try:
            for future in concurrent.futures.as_completed(futures):
                results[futures[future]] = future.result()
        except BaseException:
            pool.shutdown(wait=False, cancel_futures=True)
            raise
    return results


def size_of(path):
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def strip_dot_slash(path):
    """luacheck drops a leading ./ from every path (luacheck/runner.lua, _prepare_inputs)."""
    return re.sub(r"^\./(?=[^/])", "", path)


def walk_sorted(top, keep):
    """Every file under top (recursively, following links like luacheck and busted) for which
    keep(path) holds, as paths that start with top, sorted as Lua's table.sort sorts strings."""
    found = []
    for folder, _dirnames, filenames in os.walk(top, followlinks=True):
        for name in filenames:
            path = os.path.join(folder, name)
            if keep(path) and os.path.isfile(path):
                found.append(path)
    return sorted(found, key=lambda path: path.encode("utf-8", "surrogateescape"))


# ---------------------------------------------------------------------------
# luacheck
# ---------------------------------------------------------------------------


def luacheck_files(paths):
    """The files `luacheck PATH...` checks, in its order: each directory's *.lua files sorted, a file as
    given, in the order of the arguments (luacheck/fs.lua, extract_files)."""
    files = []
    for path in paths:
        if os.path.isdir(path):
            files.extend(strip_dot_slash(f) for f in walk_sorted(path, lambda f: f.endswith(".lua")))
        else:
            files.append(strip_dot_slash(path))
    return files


def luacheck_sets_include_files(directory="."):
    """Whether the .luacheckrc luacheck would read (the nearest one, from directory up) sets include_files."""
    folder = os.path.abspath(directory)
    while True:
        config = os.path.join(folder, ".luacheckrc")
        if os.path.isfile(config):
            with open(config, encoding="utf-8", errors="replace") as handle:
                return "include_files" in handle.read()
        parent = os.path.dirname(folder)
        if parent == folder:
            return False
        folder = parent


def luacheck_shards(files, jobs, size=size_of):
    """The files split into shards for one luacheck process each: at most jobs shards and at least
    LUACHECK_FILES_PER_SHARD files a shard (a luacheck start costs about as much as checking a small
    file), filled largest file first into the lightest shard; each shard keeps the order of files."""
    count = max(1, min(jobs, -(-len(files) // LUACHECK_FILES_PER_SHARD)))
    loads = [0] * count
    members = [[] for _ in range(count)]
    for index in sorted(range(len(files)), key=lambda i: (-size(files[i]), i)):
        lightest = min(range(count), key=lambda shard: (loads[shard], shard))
        loads[lightest] += size(files[index])
        members[lightest].append(index)
    return [[files[i] for i in sorted(indexes)] for indexes in members if indexes]


@dataclasses.dataclass
class LuacheckRun:
    blocks: dict  # file -> its report (header and any warnings), without trailing newlines
    warnings: int
    errors: int
    checked: int  # files checked: not those that could not be read, nor those exclude_files names
    fatals: int
    colored: bool


def parse_luacheck(output, files):
    """One run over files, in luacheck's default format (luacheck/format.lua: each file's report, a
    blank line, the Total line); None when the output does not end with a Total line (a critical
    error). Each report starts with a line "Checking FILE", padded, and its status."""
    text = output.rstrip("\n")
    head, _, last = text.rpartition("\n")
    match = LUACHECK_TOTAL_RE.match(ANSI_RE.sub("", last))
    if not match:
        return None
    warnings, errors, checked, fatals = (int(group or 0) for group in match.groups())
    # The reports come in the order of the files; one exclude_files names has none. A warning line is
    # indented, so only a report's first line starts with "Checking ".
    blocks, current, following = {}, None, 0
    for line in head.split("\n"):
        found = None
        if line.startswith("Checking "):
            for index in range(following, len(files)):
                if line.startswith("Checking %s " % files[index]):
                    found = index
                    break
        if found is not None:
            current, following = files[found], found + 1
            blocks[current] = [line]
        elif current is not None:
            blocks[current].append(line)
    blocks = {path: "\n".join(lines).rstrip("\n") for path, lines in blocks.items()}
    return LuacheckRun(blocks, warnings, errors, checked, fatals, "\x1b[" in last)


def luacheck_number(number, colored):
    """A count of the Total line as luacheck writes it (format.lua, format_number)."""
    if not colored:
        return str(number)
    return "\x1b[0m\x1b[%sm\x1b[1m%d\x1b[0m" % ("31" if number > 0 else "0", number)


def plural(number):
    return "" if number == 1 else "s"


def merge_luacheck(files, runs):
    """What one luacheck run over all the files prints. A report of one line (an OK file) is followed by
    a newline, a longer one (warnings, or a file that could not be checked) ends with an empty line."""
    blocks = {}
    for run in runs:
        blocks.update(run.blocks)
    parts = []
    for path in files:
        block = blocks.get(path)
        if block:
            parts.append(block + ("\n" if "\n" not in block else "\n\n"))
    body = "".join(parts)
    if body and not body.endswith("\n\n"):
        body += "\n"
    warnings = sum(r.warnings for r in runs)
    errors = sum(r.errors for r in runs)
    checked = sum(r.checked for r in runs)
    fatals = sum(r.fatals for r in runs)
    colored = any(r.colored for r in runs)
    total = "Total: %s warning%s / %s error%s in %d file%s" % (
        luacheck_number(warnings, colored),
        plural(warnings),
        luacheck_number(errors, colored),
        plural(errors),
        checked,
        plural(checked),
    )
    if fatals:
        total += ", couldn't check %d file%s" % (fatals, plural(fatals))
    if fatals:
        status = LUACHECK_EXIT["fatals"]
    elif errors:
        status = LUACHECK_EXIT["errors"]
    elif warnings:
        status = LUACHECK_EXIT["warnings"]
    else:
        status = LUACHECK_EXIT["ok"]
    return body + total + "\n", status


def cmd_luacheck(paths, jobs, out):
    paths = paths or ["src", "tests", "tools"]
    if luacheck_sets_include_files():
        print("parallel.py: .luacheckrc sets include_files; running one serial luacheck", file=sys.stderr)
        result = run_one(["luacheck", *paths])
        out.write(result.output)
        return result.returncode
    files = luacheck_files(paths)
    shards = luacheck_shards(files, jobs)
    results = run_all([["luacheck", *shard] for shard in shards], [sum(map(size_of, s)) for s in shards], jobs)
    runs = []
    for shard, result in zip(shards, results, strict=True):
        run = parse_luacheck(result.output, shard)
        if run is None:
            out.write(result.output)
            return LUACHECK_EXIT["critical"]
        runs.append(run)
    text, status = merge_luacheck(files, runs)
    out.write(text)
    return status


# ---------------------------------------------------------------------------
# busted
# ---------------------------------------------------------------------------


def busted_files(roots):
    """The spec files `busted ROOT...` runs: a file as given, else every *.lua under the root whose name
    holds "_spec" (.busted's pattern), outside hidden /.x.y paths, sorted (busted/modules/test_file_loader.lua)."""
    files = []
    for root in roots:
        if os.path.isfile(root):
            files.append(root)
            continue

        def keep(path):
            return (
                path.endswith(".lua")
                and "_spec" in os.path.basename(path)
                and not re.search(r"/\.[A-Za-z0-9]+.[A-Za-z0-9]+", path.replace(os.sep, "/"))
            )

        files.extend(walk_sorted(root, keep))
    return files


@dataclasses.dataclass
class BustedFile:
    successes: int = 0
    failures: int = 0
    errors: int = 0
    pending: int = 0
    clean: bool = False  # only the progress line and the summary: nothing worth printing


def parse_busted(result):
    """A spec file's counts from its plainTerminal output; a run without a summary line (busted died)
    counts as one error."""
    matches = list(BUSTED_SUMMARY_RE.finditer(result.output))
    if not matches:
        return BustedFile(errors=1)
    match = matches[-1]
    counts = BustedFile(*(int(group) for group in match.groups()))
    before = result.output[: match.start()].strip("\n")
    after = result.output[match.end() :].strip()
    counts.clean = (
        result.returncode == 0
        and not (counts.failures or counts.errors or counts.pending)
        and BUSTED_PROGRESS_RE.fullmatch(before) is not None
        and not after
    )
    if result.returncode != 0 and not (counts.failures or counts.errors):
        counts.errors = 1  # busted failed with nothing counted: show it as an error
    return counts


def busted_seconds(seconds):
    """busted's way of writing the time: %.6f without its trailing zeros (one kept)."""
    return re.sub(r"([0-9])0+$", r"\1", "%.6f" % seconds)


def busted_summary(successes, failures, errors, pending, seconds):
    return "%d %s / %d %s / %d %s / %d pending : %s seconds" % (
        successes,
        "success" if successes == 1 else "successes",
        failures,
        "failure" if failures == 1 else "failures",
        errors,
        "error" if errors == 1 else "errors",
        pending,
        busted_seconds(seconds),
    )


def cmd_busted(roots, jobs, out, clock=time.monotonic):
    started = clock()
    files = busted_files(roots or ["tests"])
    results = run_all([["busted", "--output=plainTerminal", path] for path in files], [size_of(f) for f in files], jobs)
    totals = BustedFile()
    for path, result in zip(files, results, strict=True):
        counts = parse_busted(result)
        for field in ("successes", "failures", "errors", "pending"):
            setattr(totals, field, getattr(totals, field) + getattr(counts, field))
        if not counts.clean:
            out.write("== busted %s (exit %d)\n%s\n" % (path, result.returncode, result.output.rstrip("\n")))
            out.write("\n")
    out.write(busted_summary(totals.successes, totals.failures, totals.errors, totals.pending, clock() - started))
    out.write("\n")
    return 1 if totals.failures or totals.errors else 0


# ---------------------------------------------------------------------------
# unittest
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class UnittestModule:
    ran: int = 0
    failures: int = 0
    errors: int = 0
    skipped: int = 0
    expected_failures: int = 0
    unexpected_successes: int = 0
    passed: bool = False
    clean: bool = False  # only the progress line and the summary: nothing worth printing


def parse_unittest(result):
    """A module's counts from unittest's summary; a run without one (the interpreter died) is one error."""
    text = ANSI_RE.sub("", result.output)
    ran = UNITTEST_RAN_RE.findall(text)
    status = UNITTEST_STATUS_RE.findall(text)
    if not ran or not status:
        return UnittestModule(errors=1)
    module = UnittestModule(ran=int(ran[-1]))
    word, details = status[-1]
    for item in filter(None, (part.strip() for part in details.split(","))):
        key, _, value = item.partition("=")
        field = key.strip().replace(" ", "_")
        if hasattr(module, field) and value.strip().isdigit():
            setattr(module, field, int(value))
    # unittest exits 5 for a module without tests (Python 3.12+); that is no failure of the whole run.
    module.passed = word in ("OK", "NO TESTS RAN") and result.returncode in (0, 5)
    before = text[: text.rfind(UNITTEST_SEPARATOR)].strip("\n") if UNITTEST_SEPARATOR in text else text
    module.clean = module.passed and UNITTEST_PROGRESS_RE.fullmatch(before) is not None
    if not module.passed and not (module.failures or module.errors or module.unexpected_successes):
        module.errors = 1
    return module


def unittest_modules(directory):
    if not os.path.isdir(directory):
        raise UsageError("no such directory: %s" % directory)
    names = sorted(name for name in os.listdir(directory) if name.startswith("test") and name.endswith(".py"))
    return [name for name in names if os.path.isfile(os.path.join(directory, name))]


def unittest_summary(total, seconds):
    lines = [UNITTEST_SEPARATOR, "Ran %d test%s in %.3fs" % (total.ran, "" if total.ran == 1 else "s", seconds), ""]
    infos = []
    if not total.passed:
        word = "FAILED"
        if total.failures:
            infos.append("failures=%d" % total.failures)
        if total.errors:
            infos.append("errors=%d" % total.errors)
    elif total.ran == 0 and not total.skipped:
        word = "NO TESTS RAN"
    else:
        word = "OK"
    if total.skipped:
        infos.append("skipped=%d" % total.skipped)
    if total.expected_failures:
        infos.append("expected failures=%d" % total.expected_failures)
    if total.unexpected_successes:
        infos.append("unexpected successes=%d" % total.unexpected_successes)
    lines.append(word + (" (%s)" % ", ".join(infos) if infos else ""))
    return "\n".join(lines) + "\n"


def cmd_unittest(directory, jobs, out, clock=time.monotonic):
    started = clock()
    directory = directory or os.path.join("tools", "tests")
    names = unittest_modules(directory)
    commands = [[sys.executable, "-B", "-m", "unittest", "discover", "-s", directory, "-p", name] for name in names]
    results = run_all(commands, [size_of(os.path.join(directory, name)) for name in names], jobs)
    total = UnittestModule(passed=True)
    for name, result in zip(names, results, strict=True):
        module = parse_unittest(result)
        for field in ("ran", "failures", "errors", "skipped", "expected_failures", "unexpected_successes"):
            setattr(total, field, getattr(total, field) + getattr(module, field))
        if not module.passed:
            total.passed = False
        if not module.clean:
            out.write("== unittest %s (exit %d)\n%s\n\n" % (name, result.returncode, result.output.rstrip("\n")))
    out.write(unittest_summary(total, clock() - started))
    if not total.passed:
        return 1
    return 5 if total.ran == 0 and not total.skipped else 0


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="parallel.py",
        description="Run luacheck, busted or the Python unit tests as one process per file on every core "
        "(JOBS at once, default nproc), printing what a serial run prints (issue #456).",
        epilog="JOBS=1 runs one file at a time. Exit codes: as the tool's own; 2 usage.",
    )
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    lint = commands.add_parser("luacheck", help="luacheck PATH... (default: src tests tools)")
    lint.add_argument("paths", nargs="*", metavar="PATH")
    specs = commands.add_parser("busted", help="busted ROOT... (default: tests)")
    specs.add_argument("paths", nargs="*", metavar="ROOT")
    units = commands.add_parser("unittest", help="python3 -B -m unittest per test*.py of DIR (default: tools/tests)")
    units.add_argument("paths", nargs="?", metavar="DIR")
    return parser.parse_args(argv)


def main(argv, out=None):
    out = out or sys.stdout
    args = parse_args(argv)
    try:
        jobs = job_count()
        if args.command == "luacheck":
            return cmd_luacheck(args.paths, jobs, out)
        if args.command == "busted":
            return cmd_busted(args.paths, jobs, out)
        return cmd_unittest(args.paths, jobs, out)
    except UsageError as err:
        print("parallel.py: error: %s" % err, file=sys.stderr)
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
