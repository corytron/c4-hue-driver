#!/usr/bin/env python3
"""Check that no function of the drivers' Lua comes near Lua 5.1's limits on locals and upvalues.

  lua_limits.py [--root DIR] [--luac PROGRAM] [--verbose]

Issue #373 (docs/driver-locals-design.md): Lua 5.1 compiles a function only while it has at most 200
active local variables (LUAI_MAXVARS) and at most 60 upvalues (LUAI_MAXUPVALUES), and the main chunk of
every file is a function too. The bridge driver's main chunk reached 199 locals before anyone noticed:
one more file-level local and lint, every spec and the build would have stopped. This check, run by
tools/check.sh as "lua-limits" and in CI's "Lint and test (Lua 5.1)" job, fails as soon as a function
has more than MAX_LOCALS (180) locals or more than MAX_UPVALUES (50) upvalues, so the headroom shrinks
visibly, and on every pull request, long before the compiler refuses.

How: every *.lua file under src/ (walked on disk, tracked or not, as luacheck does) is compiled with
`luac5.1 -p -l -l FILE` (parse only: nothing is written), one file a run, and the listing is read. Each
"main <FILE:0,0>" or "function <FILE:L,M>" header starts a function, and its "locals (N) for ADDRESS:"
and "upvalues (N) for ADDRESS:" lines give its counts.

The measure of locals is conservative on purpose: luac's "locals (N)" counts every local the function
declares, those of inner blocks and loops (the hidden "(for index)" ones included) as well as those
alive at the same time, whereas the compiler's limit counts only the locals active at once. A function
within MAX_LOCALS here is at least that far below the hard limit. The upvalue count is exact.

A file luac5.1 cannot compile fails too: a syntax error (which lua-lint also reports), or a function
already past a hard limit, in which case the message points at the design document as well.

Output: one line per problem, of the forms
  FILE: main chunk: N locals, more than the limit of 180 (Lua 5.1 compiles at most 200 active locals in a
  function); see docs/driver-locals-design.md
  FILE: function at line L: N upvalues, more than the limit of 50 (Lua 5.1 compiles at most 60 upvalues
  in a function); see docs/driver-locals-design.md
  FILE: luac5.1 cannot compile it: MESSAGE
(each on one line), then the summary "lua-limits: N files, M functions, K problems; most locals C (limit
180): FILE, FUNCTION; most upvalues C (limit 50): FILE, FUNCTION", which shows the headroom left.
--verbose first prints each file's highest counts.

Standard library only. Exit codes: 0 every function within the limits, 1 a function over a limit or a
file luac5.1 cannot compile or list, 2 usage (argparse, luac5.1 not installed, no *.lua under src/).
"""

import argparse
import dataclasses
import os
import re
import shutil
import subprocess
import sys

EXIT_OK, EXIT_OVER, EXIT_USAGE = 0, 1, 2

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUAC = "luac5.1"
SOURCES = "src"
DESIGN = "docs/driver-locals-design.md"

# The limits of this check, each well below the hard limit of Lua 5.1 it guards (luaconf.h).
MAX_LOCALS = 180
MAX_UPVALUES = 50
LUA_MAX_LOCALS = 200  # LUAI_MAXVARS: the locals active at once in one function
LUA_MAX_UPVALUES = 60  # LUAI_MAXUPVALUES

# Seconds one luac5.1 run may take; the largest driver compiles in well under one.
LUAC_TIMEOUT = 60

# A function's header and the debug sections of a `luac5.1 -l -l` listing (luac.c, PrintHeader and
# PrintDebug), matched against whole lines that start in column 0.
HEADER_RE = re.compile(r"(main|function) <(.*):(\d+),(\d+)> \(\d+ instructions?, \d+ bytes at (\S+)\)")
SECTION_RE = re.compile(r"(constants|locals|upvalues) \((\d+)\) for (\S+):")
# How luac5.1 refuses a function past a hard limit (lparser.c, errorlimit).
HARD_LIMIT_RE = re.compile(r"has more than \d+ (?:local variables|upvalues)")


class UsageError(Exception):
    """A run that cannot start: printed to stderr, exit 2."""


class ListingError(Exception):
    """A luac listing this script cannot read: reported as a problem of the file."""


@dataclasses.dataclass
class Function:
    """One function of a listing: the line it starts on (0 for the main chunk) and its counts."""

    line: int
    locals: int | None = None
    upvalues: int | None = None

    @property
    def name(self):
        return "main chunk" if self.line == 0 else "function at line %d" % self.line


@dataclasses.dataclass
class Report:
    """What check() found: how many files it read, the functions of each file it could list, and
    every problem as the line to print."""

    files: int = 0
    listed: list = dataclasses.field(default_factory=list)  # (path, [Function, ...])
    problems: list = dataclasses.field(default_factory=list)

    @property
    def functions(self):
        return sum(len(functions) for _path, functions in self.listed)


def parse_listing(listing):
    """The functions of a `luac5.1 -p -l -l` listing, in the order listed (the main chunk first). Only
    lines starting in column 0 can match: luac indents instructions, constants and the names of locals
    and upvalues with a tab and escapes newlines in strings, so no text of the program passes for a
    header or a section line. A section belongs to the function whose header gave its address."""
    functions = []
    by_address = {}
    for number, line in enumerate(listing.splitlines(), 1):
        header = HEADER_RE.fullmatch(line)
        if header:
            address = header.group(5)
            if address in by_address:
                raise ListingError("line %d: a second function at %s" % (number, address))
            function = Function(int(header.group(3)))
            functions.append(function)
            by_address[address] = function
            continue
        section = SECTION_RE.fullmatch(line)
        if section is None or section.group(1) == "constants":
            continue
        kind, count, address = section.group(1), int(section.group(2)), section.group(3)
        function = by_address.get(address)
        if function is None:
            raise ListingError("line %d: %s of a function the listing has no header for (%s)" % (number, kind, address))
        if kind == "locals":
            function.locals = count
        else:
            function.upvalues = count
    if not functions or functions[0].line != 0:
        raise ListingError("it does not start with the main chunk")
    for function in functions:
        if function.locals is None or function.upvalues is None:
            raise ListingError("no locals or upvalues line for the %s (not run with -l -l?)" % function.name)
    return functions


def lua_files(root):
    """Every *.lua file under root's src/, as root-relative paths with forward slashes, sorted."""
    top = os.path.join(root, SOURCES)
    if not os.path.isdir(top):
        raise UsageError("%s has no %s/ folder" % (root, SOURCES))
    found = []
    for folder, dirnames, filenames in os.walk(top):
        dirnames.sort()
        for name in filenames:
            if name.endswith(".lua"):
                found.append(os.path.relpath(os.path.join(folder, name), root).replace(os.sep, "/"))
    if not found:
        raise UsageError("no *.lua file under %s" % top)
    return sorted(found)


def run_luac(luac, root, path):
    """(exit status, standard output, standard error) of `luac -p -l -l path`, run in root; the unit
    tests replace this function."""
    try:
        done = subprocess.run(
            [luac, "-p", "-l", "-l", path], cwd=root, capture_output=True, check=False, timeout=LUAC_TIMEOUT
        )
    except (OSError, subprocess.TimeoutExpired) as err:
        raise UsageError("cannot run %s on %s: %s" % (luac, path, err)) from err
    return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")


def over_limit(path, function, noun, count, limit, hard_limit, hard_noun):
    """The problem line of a function with more than limit of something."""
    return "%s: %s: %d %s, more than the limit of %d (Lua 5.1 compiles at most %d %s in a function); see %s" % (
        path,
        function.name,
        count,
        noun,
        limit,
        hard_limit,
        hard_noun,
        DESIGN,
    )


def compile_failure(luac, path, errors):
    """The problem line of a file luac could not compile, from its standard error ("PROGRAM: MESSAGE")."""
    text = " ".join(line.strip() for line in errors.strip().splitlines()) or "no message"
    if text.startswith(luac + ": "):
        text = text[len(luac) + 2 :]
    problem = "%s: %s cannot compile it: %s" % (path, os.path.basename(luac), text)
    if HARD_LIMIT_RE.search(text):
        problem += "; see %s" % DESIGN
    return problem


def check(root, luac=LUAC):
    """Compile every Lua file under root's src/ with luac and compare each function's counts with the
    limits."""
    paths = lua_files(root)
    report = Report(files=len(paths))
    for path in paths:
        status, listing, errors = run_luac(luac, root, path)
        if status != 0:
            report.problems.append(compile_failure(luac, path, errors))
            continue
        try:
            functions = parse_listing(listing)
        except ListingError as err:
            report.problems.append("%s: cannot read the listing of %s -p -l -l: %s" % (path, luac, err))
            continue
        report.listed.append((path, functions))
        for function in functions:
            if function.locals > MAX_LOCALS:
                report.problems.append(
                    over_limit(path, function, "locals", function.locals, MAX_LOCALS, LUA_MAX_LOCALS, "active locals")
                )
            if function.upvalues > MAX_UPVALUES:
                report.problems.append(
                    over_limit(
                        path, function, "upvalues", function.upvalues, MAX_UPVALUES, LUA_MAX_UPVALUES, "upvalues"
                    )
                )
    return report


def peak(listed, attribute):
    """(count, path, function) of the function with the most of attribute ("locals" or "upvalues"),
    the first listed on a tie; None when nothing was listed."""
    best = None
    for path, functions in listed:
        for function in functions:
            count = getattr(function, attribute)
            if best is None or count > best[0]:
                best = (count, path, function)
    return best


def plural(count, noun):
    return "%d %s%s" % (count, noun, "" if count == 1 else "s")


def file_line(path, functions):
    """--verbose: a file's highest counts."""
    parts = []
    for attribute in ("locals", "upvalues"):
        count, _path, function = peak([(path, functions)], attribute)
        parts.append("most %s %d (%s)" % (attribute, count, function.name))
    return "%s: %s" % (path, ", ".join(parts))


def summary(report):
    """The last line of the output: what was read, how many problems, and the highest counts."""
    parts = [
        "lua-limits: %s, %s, %s"
        % (plural(report.files, "file"), plural(report.functions, "function"), plural(len(report.problems), "problem"))
    ]
    for attribute, limit in (("locals", MAX_LOCALS), ("upvalues", MAX_UPVALUES)):
        best = peak(report.listed, attribute)
        if best is not None:
            count, path, function = best
            parts.append("most %s %d (limit %d): %s, %s" % (attribute, count, limit, path, function.name))
    return "; ".join(parts)


def directory(text):
    if not os.path.isdir(text):
        raise argparse.ArgumentTypeError("not a directory: %r" % text)
    return text


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="lua_limits.py",
        description="Compile every *.lua file under src/ with `luac5.1 -p -l -l` and fail when a function "
        "(main chunks included) has more than %d locals or more than %d upvalues; Lua 5.1 stops compiling at "
        "%d active locals and %d upvalues (issue #373, %s)."
        % (MAX_LOCALS, MAX_UPVALUES, LUA_MAX_LOCALS, LUA_MAX_UPVALUES, DESIGN),
        epilog="Output: one line per problem, then 'lua-limits: N files, M functions, K problems' with the highest "
        "counts. Exit codes: 0 within the limits, 1 a function over a limit or a file that does not compile, 2 usage.",
    )
    parser.add_argument(
        "--root",
        type=directory,
        default=ROOT,
        metavar="DIR",
        help="the folder whose src/ is checked (default: the repository this script is in)",
    )
    parser.add_argument(
        "--luac",
        default=LUAC,
        metavar="PROGRAM",
        help="Lua 5.1's compiler, a name on PATH or a path (default: %s)" % LUAC,
    )
    parser.add_argument("--verbose", action="store_true", help="first print every file's highest counts")
    return parser.parse_args(argv)


def main(argv):
    args = parse_args(argv)
    try:
        if shutil.which(args.luac) is None:
            raise UsageError(
                "%s is not installed (not found on PATH): this check needs Lua 5.1's compiler, which Ubuntu's "
                'lua5.1 package installs as luac5.1 (CI\'s "Lint and test (Lua 5.1)" job has it)' % args.luac
            )
        report = check(args.root, args.luac)
    except UsageError as err:
        print("lua_limits.py: error: %s" % err, file=sys.stderr)
        return EXIT_USAGE
    if args.verbose:
        for path, functions in report.listed:
            print(file_line(path, functions))
    for problem in report.problems:
        print(problem)
    print(summary(report))
    return EXIT_OVER if report.problems else EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
