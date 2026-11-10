"""Unit tests for tools/lua_limits.py (issue #373): synthetic luac5.1 listings everywhere, and, when
luac5.1 is installed, small generated Lua files compiled in temporary directories. Only
RealRepositoryListing reads this repository, read-only, and it never fails on the counts it finds.

Run: python3 -m unittest discover -s tools/tests -v
"""

import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

import lua_limits  # noqa: E402

SCRIPT = os.path.join(TOOLS, "lua_limits.py")
HAVE_LUAC = shutil.which(lua_limits.LUAC) is not None
NEEDS_LUAC = unittest.skipUnless(HAVE_LUAC, "luac5.1 is not installed")

# What `luac5.1 -p -l -l s.lua` printed for a small file (Lua 5.1.5), the addresses replaced:
#   local a, b = 1, 2 / local function f(x) return a + x end / for i = 1, 2 do local c = i end / return f
SAMPLE = """
main <s.lua:0,0> (12 instructions, 48 bytes at 0x55d0aa000100)
0+ params, 8 slots, 0 upvalues, 8 locals, 2 constants, 1 function
\t1\t[1]\tLOADK    \t0 -1\t; 1
\t2\t[1]\tLOADK    \t1 -2\t; 2
\t3\t[4]\tCLOSURE  \t2 0\t; 0x55d0aa000200
\t4\t[4]\tMOVE     \t0 0
\t5\t[5]\tLOADK    \t3 -1\t; 1
\t6\t[5]\tLOADK    \t4 -2\t; 2
\t7\t[5]\tLOADK    \t5 -1\t; 1
\t8\t[5]\tFORPREP  \t3 1\t; to 10
\t9\t[6]\tMOVE     \t7 6
\t10\t[5]\tFORLOOP  \t3 -2\t; to 9
\t11\t[8]\tRETURN   \t2 2
\t12\t[8]\tRETURN   \t0 1
constants (2) for 0x55d0aa000100:
\t1\t1
\t2\t2
locals (8) for 0x55d0aa000100:
\t0\ta\t3\t12
\t1\tb\t3\t12
\t2\tf\t5\t12
\t3\t(for index)\t8\t11
\t4\t(for limit)\t8\t11
\t5\t(for step)\t8\t11
\t6\ti\t9\t10
\t7\tc\t10\t10
upvalues (0) for 0x55d0aa000100:

function <s.lua:2,4> (4 instructions, 16 bytes at 0x55d0aa000200)
1 param, 2 slots, 1 upvalue, 1 local, 0 constants, 0 functions
\t1\t[3]\tGETUPVAL \t1 0\t; a
\t2\t[3]\tADD      \t1 1 0
\t3\t[3]\tRETURN   \t1 2
\t4\t[4]\tRETURN   \t0 1
constants (0) for 0x55d0aa000200:
locals (1) for 0x55d0aa000200:
\t0\tx\t1\t4
upvalues (1) for 0x55d0aa000200:
\t0\ta
"""


def listing(*functions, source="src/x.lua"):
    """A `luac5.1 -p -l -l` listing in luac's format of functions given as (first line, locals,
    upvalues), the first one the main chunk (first line 0); the addresses are invented."""
    out = []
    for index, (line, nlocals, nupvalues) in enumerate(functions):
        address = "0x55d0aa%06x" % (index * 0x100 + 0x100)
        kind = "main" if line == 0 else "function"
        out.append("")
        out.append("%s <%s:%d,%d> (1 instruction, 4 bytes at %s)" % (kind, source, line, line, address))
        out.append("0+ params, 2 slots, %d upvalues, %d locals, 1 constant, 0 functions" % (nupvalues, nlocals))
        out.append('\t1\t[1]\tLOADK    \t0 -1\t; "locals (999) for %s:"' % address)
        out.append("constants (1) for %s:" % address)
        out.append('\t1\t"upvalues (999) for %s:"' % address)
        out.append("locals (%d) for %s:" % (nlocals, address))
        out.extend("\t%d\tv%d\t1\t1" % (n, n) for n in range(nlocals))
        out.append("upvalues (%d) for %s:" % (nupvalues, address))
        out.extend("\t%d\tu%d" % (n, n) for n in range(nupvalues))
    return "\n".join(out) + "\n"


def locals_message(path, function, count):
    return (
        "%s: %s: %d locals, more than the limit of 180 (Lua 5.1 compiles at most 200 active locals in a function); "
        "see docs/driver-locals-design.md" % (path, function, count)
    )


def upvalues_message(path, function, count):
    return (
        "%s: %s: %d upvalues, more than the limit of 50 (Lua 5.1 compiles at most 60 upvalues in a function); "
        "see docs/driver-locals-design.md" % (path, function, count)
    )


class ParseListing(unittest.TestCase):
    def test_reads_luacs_own_listing(self):
        functions = lua_limits.parse_listing(SAMPLE)
        self.assertEqual(
            [(f.line, f.name, f.locals, f.upvalues) for f in functions],
            [(0, "main chunk", 8, 0), (2, "function at line 2", 1, 1)],
        )

    def test_text_of_the_program_never_passes_for_a_section(self):
        # listing() puts "locals (999) for ..." in an instruction and a constant, indented as luac does.
        functions = lua_limits.parse_listing(listing((0, 3, 0), (7, 2, 4)))
        self.assertEqual([(f.line, f.locals, f.upvalues) for f in functions], [(0, 3, 0), (7, 2, 4)])

    def test_sections_belong_to_the_function_of_their_address(self):
        # The main chunk's sections moved after the inner function's: still the main chunk's counts.
        begin = SAMPLE.index("constants (2) for 0x55d0aa000100:")
        stop = SAMPLE.index("\nfunction <s.lua:2,4>")
        moved = SAMPLE[:begin] + SAMPLE[stop:] + SAMPLE[begin:stop]
        functions = lua_limits.parse_listing(moved)
        self.assertEqual([(f.line, f.locals, f.upvalues) for f in functions], [(0, 8, 0), (2, 1, 1)])

    def test_a_listing_without_debug_sections_is_refused(self):
        single = "\n".join(line for line in SAMPLE.splitlines() if not line.startswith(("locals", "upvalues")))
        with self.assertRaisesRegex(lua_limits.ListingError, "no locals or upvalues line for the main chunk"):
            lua_limits.parse_listing(single)

    def test_an_empty_listing_is_refused(self):
        with self.assertRaisesRegex(lua_limits.ListingError, "main chunk"):
            lua_limits.parse_listing("")

    def test_a_section_of_an_unknown_function_is_refused(self):
        text = SAMPLE.replace("upvalues (1) for 0x55d0aa000200:", "upvalues (1) for 0x55d0aa000900:")
        with self.assertRaisesRegex(lua_limits.ListingError, "no header for"):
            lua_limits.parse_listing(text)

    def test_two_functions_at_one_address_are_refused(self):
        text = SAMPLE.replace("bytes at 0x55d0aa000200", "bytes at 0x55d0aa000100")
        with self.assertRaisesRegex(lua_limits.ListingError, "a second function"):
            lua_limits.parse_listing(text)


class FakeTree(unittest.TestCase):
    """A temporary root with Lua files under src/; luac is replaced by listings or errors per file."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name
        self.results = {}  # path: (status, stdout, stderr)
        patcher = mock.patch.object(lua_limits, "run_luac", self.fake_luac)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_luac(self, luac, root, path):
        self.assertEqual((luac, root), (lua_limits.LUAC, self.root))
        return self.results[path]

    def add(self, path, text=None, status=0, errors=""):
        full = os.path.join(self.root, *path.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write("-- generated by test_lua_limits.py\n")
        self.results[path] = (status, text or "", errors)

    def test_at_the_limits_passes(self):
        self.add("src/a/driver.lua", listing((0, 180, 0), (12, 4, 50)))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [])
        self.assertEqual((report.files, report.functions), (1, 2))

    def test_one_local_over_fails_naming_the_main_chunk(self):
        self.add("src/a/driver.lua", listing((0, 181, 0)))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [locals_message("src/a/driver.lua", "main chunk", 181)])

    def test_one_upvalue_over_fails_naming_the_functions_line(self):
        self.add("src/a/m.lua", listing((0, 10, 0), (7, 3, 51)))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [upvalues_message("src/a/m.lua", "function at line 7", 51)])

    def test_both_limits_of_one_function_are_reported(self):
        self.add("src/a/m.lua", listing((0, 10, 0), (30, 190, 55)))
        report = lua_limits.check(self.root)
        self.assertEqual(
            report.problems,
            [
                locals_message("src/a/m.lua", "function at line 30", 190),
                upvalues_message("src/a/m.lua", "function at line 30", 55),
            ],
        )

    def test_every_lua_file_under_src_is_read_and_only_those(self):
        self.add("src/b/driver.lua", listing((0, 5, 0)))
        self.add("src/a/deep/er/mod.lua", listing((0, 6, 0)))
        self.add("src/a/README.md")
        self.add("tests/spec/x_spec.lua")
        self.assertEqual(lua_limits.lua_files(self.root), ["src/a/deep/er/mod.lua", "src/b/driver.lua"])
        self.assertEqual(lua_limits.check(self.root).files, 2)

    def test_a_file_that_does_not_compile_fails(self):
        self.add("src/a/bad.lua", status=1, errors="luac5.1: src/a/bad.lua:2: unexpected symbol near '<eof>'\n")
        report = lua_limits.check(self.root)
        self.assertEqual(
            report.problems,
            ["src/a/bad.lua: luac5.1 cannot compile it: src/a/bad.lua:2: unexpected symbol near '<eof>'"],
        )

    def test_a_file_past_a_hard_limit_points_at_the_design(self):
        errors = "luac5.1: src/a/big.lua:201: main function has more than 200 local variables\n"
        self.add("src/a/big.lua", status=1, errors=errors)
        self.add(
            "src/a/up.lua", status=1, errors="luac5.1: src/a/up.lua:63: function at line 63 has more than 60 upvalues\n"
        )
        report = lua_limits.check(self.root)
        self.assertEqual(
            report.problems,
            [
                "src/a/big.lua: luac5.1 cannot compile it: src/a/big.lua:201: main function has more than 200 "
                "local variables; see docs/driver-locals-design.md",
                "src/a/up.lua: luac5.1 cannot compile it: src/a/up.lua:63: function at line 63 has more than 60 "
                "upvalues; see docs/driver-locals-design.md",
            ],
        )

    def test_a_listing_it_cannot_read_fails(self):
        self.add("src/a/odd.lua", "not a listing\n")
        report = lua_limits.check(self.root)
        self.assertEqual(len(report.problems), 1)
        self.assertTrue(report.problems[0].startswith("src/a/odd.lua: cannot read the listing of luac5.1 -p -l -l"))

    def test_summary_names_the_highest_counts_and_their_files(self):
        self.add("src/a/driver.lua", listing((0, 120, 0), (40, 3, 17)))
        self.add("src/b/driver.lua", listing((0, 150, 0), (9, 151, 2), (12, 4, 17)))
        report = lua_limits.check(self.root)
        self.assertEqual(
            lua_limits.summary(report),
            "lua-limits: 2 files, 5 functions, 0 problems; most locals 151 (limit 180): src/b/driver.lua, "
            "function at line 9; most upvalues 17 (limit 50): src/a/driver.lua, function at line 40",
        )

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with (
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
            mock.patch.object(lua_limits.shutil, "which", return_value="/usr/bin/luac5.1"),
        ):
            status = lua_limits.main(["--root", self.root, *argv])
        return status, out.getvalue(), err.getvalue()

    def test_main_prints_problems_then_the_summary_and_exits_1(self):
        self.add("src/a/driver.lua", listing((0, 181, 0)))
        self.add("src/b/driver.lua", listing((0, 10, 0)))
        status, out, err = self.run_main()
        self.assertEqual((status, err), (1, ""))
        self.assertEqual(
            out.splitlines(),
            [
                locals_message("src/a/driver.lua", "main chunk", 181),
                "lua-limits: 2 files, 2 functions, 1 problem; most locals 181 (limit 180): src/a/driver.lua, "
                "main chunk; most upvalues 0 (limit 50): src/a/driver.lua, main chunk",
            ],
        )

    def test_main_verbose_lists_every_file_first(self):
        self.add("src/a/driver.lua", listing((0, 12, 0), (3, 2, 5)))
        status, out, _err = self.run_main("--verbose")
        self.assertEqual(status, 0)
        self.assertEqual(
            out.splitlines()[0], "src/a/driver.lua: most locals 12 (main chunk), most upvalues 5 (function at line 3)"
        )
        self.assertTrue(out.splitlines()[1].startswith("lua-limits: 1 file, 2 functions, 0 problems;"))

    def test_main_without_lua_files_is_a_usage_error(self):
        os.makedirs(os.path.join(self.root, "src", "a"))
        status, out, err = self.run_main()
        self.assertEqual((status, out), (2, ""))
        self.assertIn("no *.lua file under", err)

    def test_main_without_src_is_a_usage_error(self):
        status, out, err = self.run_main()
        self.assertEqual((status, out), (2, ""))
        self.assertIn("has no src/ folder", err)


class MissingCompiler(unittest.TestCase):
    def test_no_luac_fails_with_a_clear_message(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "src"))
            with open(os.path.join(root, "src", "a.lua"), "w", encoding="utf-8") as handle:
                handle.write("return 1\n")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = lua_limits.main(["--root", root, "--luac", os.path.join(root, "no-such-luac")])
        self.assertEqual((status, out.getvalue()), (2, ""))
        self.assertIn("no-such-luac is not installed (not found on PATH)", err.getvalue())
        self.assertIn("lua5.1 package", err.getvalue())


def many_locals(count):
    """A file whose main chunk declares count locals, all alive to the end."""
    return "".join("local v%d = %d\n" % (n, n) for n in range(count))


def scoped_locals(count):
    """A file whose main chunk declares count locals, never more than one alive at a time."""
    return "".join("do local v%d = %d end\n" % (n, n) for n in range(count))


def many_upvalues(count):
    """A file whose function on line count + 1 uses count upvalues."""
    uses = " + ".join("u%d" % n for n in range(count))
    return many_locals(count).replace("local v", "local u") + "local function f()\n\treturn %s\nend\nreturn f\n" % uses


@NEEDS_LUAC
class RealCompiler(unittest.TestCase):
    """Generated Lua files compiled by the real luac5.1 in a temporary directory."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name

    def add(self, path, text):
        full = os.path.join(self.root, *path.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)

    def test_a_clean_tree_passes(self):
        self.add("src/a/driver.lua", many_locals(180))
        self.add("src/a/lib/m.lua", many_upvalues(50))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [])
        self.assertEqual(
            lua_limits.summary(report),
            "lua-limits: 2 files, 3 functions, 0 problems; most locals 180 (limit 180): src/a/driver.lua, main chunk; "
            "most upvalues 50 (limit 50): src/a/lib/m.lua, function at line 51",
        )

    def test_181_locals_fail(self):
        self.add("src/a/driver.lua", many_locals(181))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [locals_message("src/a/driver.lua", "main chunk", 181)])

    def test_scoped_locals_count_too(self):
        # Never more than one alive at a time: the compiler would take 1000 of them, the check does not.
        self.add("src/a/driver.lua", scoped_locals(181))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [locals_message("src/a/driver.lua", "main chunk", 181)])

    def test_51_upvalues_fail(self):
        self.add("src/a/m.lua", many_upvalues(51))
        report = lua_limits.check(self.root)
        self.assertEqual(report.problems, [upvalues_message("src/a/m.lua", "function at line 52", 51)])

    def test_past_the_hard_limit_fails_as_a_compile_error(self):
        self.add("src/a/driver.lua", many_locals(201))
        report = lua_limits.check(self.root)
        self.assertEqual(
            report.problems,
            [
                "src/a/driver.lua: luac5.1 cannot compile it: src/a/driver.lua:201: main function has more than "
                "200 local variables; see docs/driver-locals-design.md"
            ],
        )

    def test_the_script_end_to_end(self):
        self.add("src/a/driver.lua", many_locals(20))
        done = subprocess.run(
            [sys.executable, "-I", "-B", SCRIPT, "--root", self.root], capture_output=True, text=True, check=False
        )
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertTrue(done.stdout.startswith("lua-limits: 1 file, 1 function, 0 problems;"), done.stdout)
        self.add("src/b/driver.lua", many_locals(181))
        done = subprocess.run(
            [sys.executable, "-I", "-B", SCRIPT, "--root", self.root], capture_output=True, text=True, check=False
        )
        self.assertEqual(done.returncode, 1)
        self.assertEqual(done.stdout.splitlines()[0], locals_message("src/b/driver.lua", "main chunk", 181))


@NEEDS_LUAC
class RealRepositoryListing(unittest.TestCase):
    """luac5.1's listing of every Lua file of this repository can be read; the counts are the check's
    business, not this test's."""

    def test_every_file_lists(self):
        report = lua_limits.check(REPO)
        self.assertGreater(report.files, 0)
        self.assertEqual(len(report.listed) + sum("cannot compile" in p for p in report.problems), report.files)
        for problem in report.problems:
            self.assertNotIn("cannot read the listing", problem)
        for path, functions in report.listed:
            self.assertEqual(functions[0].name, "main chunk", path)


if __name__ == "__main__":
    unittest.main()
