"""Unit tests for tools/parallel.py (issue #456): the file lists, the shards, the parsing and merging of
each tool's output on synthetic text, and, when luacheck, busted and Python are installed, the real tools
run on small generated trees in temporary directories, serial against parallel.

Run: python3 -m unittest discover -s tools/tests -v
"""

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import parallel  # noqa: E402

SCRIPT = os.path.join(TOOLS, "parallel.py")
HAVE_LUACHECK = shutil.which("luacheck") is not None
HAVE_BUSTED = shutil.which("busted") is not None


class TreeCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = tmp.name

    def write(self, path, text=""):
        full = os.path.join(self.root, *path.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as handle:
            handle.write(text)

    def run_in_root(self, *command, jobs="3"):
        env = dict(os.environ, JOBS=jobs)
        done = subprocess.run(
            command, cwd=self.root, env=env, capture_output=True, encoding="utf-8", errors="replace", check=False
        )
        return done.returncode, done.stdout, done.stderr


class JobCount(unittest.TestCase):
    def test_jobs_sets_the_count(self):
        self.assertEqual(parallel.job_count({"JOBS": "1"}), 1)
        self.assertEqual(parallel.job_count({"JOBS": "17"}), 17)

    def test_default_is_the_cores_this_process_may_use(self):
        self.assertEqual(parallel.job_count({}), len(os.sched_getaffinity(0)))
        self.assertEqual(parallel.job_count({"JOBS": ""}), len(os.sched_getaffinity(0)))

    def test_anything_else_is_a_usage_error(self):
        for value in ("0", "-1", "x", "1.5", " 2", "02"):
            with self.subTest(value=value), self.assertRaises(parallel.UsageError):
                parallel.job_count({"JOBS": value})

    def test_main_exits_2_on_a_bad_jobs(self):
        err = io.StringIO()
        with mock.patch.dict(os.environ, {"JOBS": "lots"}), mock.patch.object(sys, "stderr", err):
            self.assertEqual(parallel.main(["busted"], out=io.StringIO()), 2)
        self.assertIn("JOBS must be a whole number from 1", err.getvalue())


class RunAll(unittest.TestCase):
    def test_results_come_in_the_order_given_and_the_heaviest_runs_first(self):
        started = []

        def runner(command):
            started.append(command[0])
            return parallel.Result(0, command[0])

        commands = [["light"], ["heavy"], ["middle"], ["heavy-too"]]
        results = parallel.run_all(commands, [1, 9, 5, 9], jobs=1, runner=runner)
        self.assertEqual([r.output for r in results], ["light", "heavy", "middle", "heavy-too"])
        self.assertEqual(started, ["heavy", "heavy-too", "middle", "light"])
        results = parallel.run_all(commands, [1, 9, 5, 9], jobs=3, runner=runner)
        self.assertEqual([r.output for r in results], ["light", "heavy", "middle", "heavy-too"])

    def test_a_missing_program_is_a_usage_error(self):
        with self.assertRaises(parallel.UsageError):
            parallel.run_all([["no-such-program-456"]], [0], jobs=2)


# ---------------------------------------------------------------------------
# luacheck
# ---------------------------------------------------------------------------


def luacheck_output(reports, total, colored=False):
    """What luacheck prints for reports (each a list of lines) and a Total line (format.lua, the
    default formatter): the reports and the Total line joined by newlines, with an empty line before
    the Total line when the last report does not end with one."""
    buf = ["\n".join(lines) for lines in reports]
    if buf and not buf[-1].endswith("\n"):
        buf.append("")
    if colored:
        total = total.replace(" 0 ", " \x1b[0m\x1b[0m\x1b[1m0\x1b[0m ").replace(
            "Total: 0 ", "Total: \x1b[0m\x1b[0m\x1b[1m0\x1b[0m "
        )
    buf.append(total)
    return "\n".join(buf) + "\n"


OK = "Checking %-41sOK"


class LuacheckFiles(TreeCase):
    def test_directories_are_expanded_sorted_in_the_order_given(self):
        for path in ("b/z.lua", "b/a/y.lua", "b/A.lua", "a/x.lua", "a/readme.md", "a/.hidden/h.lua", "c.lua"):
            self.write(path)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.root)
        self.assertEqual(
            parallel.luacheck_files(["b", "./a", "c.lua", "missing.lua"]),
            ["b/A.lua", "b/a/y.lua", "b/z.lua", "a/.hidden/h.lua", "a/x.lua", "c.lua", "missing.lua"],
        )

    def test_shards_cover_every_file_once_in_order(self):
        files = ["f%03d.lua" % n for n in range(37)]
        sizes = {name: (n * 7919) % 101 for n, name in enumerate(files)}
        for jobs in (1, 2, 3, 32):
            with self.subTest(jobs=jobs):
                shards = parallel.luacheck_shards(files, jobs, size=sizes.get)
                self.assertLessEqual(len(shards), jobs)
                self.assertLessEqual(len(shards), -(-len(files) // parallel.LUACHECK_FILES_PER_SHARD))
                self.assertEqual(sorted(name for shard in shards for name in shard), files)
                for shard in shards:
                    self.assertEqual(shard, sorted(shard))
        self.assertEqual(parallel.luacheck_shards([], 4), [])
        self.assertEqual(parallel.luacheck_shards(["a.lua"], 4, size=lambda _: 0), [["a.lua"]])

    def test_include_files_makes_one_serial_run(self):
        self.assertFalse(parallel.luacheck_sets_include_files(self.root))
        self.write(".luacheckrc", 'include_files = { "src" }\n')
        self.write("deep/er/x.lua")
        self.assertTrue(parallel.luacheck_sets_include_files(os.path.join(self.root, "deep", "er")))


class LuacheckMerge(unittest.TestCase):
    def test_shards_merge_into_one_run(self):
        warned = ["Checking b.lua%s1 warning" % (" " * 36), "", "    b.lua:1:7: unused variable 'x'", ""]
        first = luacheck_output([[OK % "a.lua"], warned], "Total: 1 warning / 0 errors in 2 files")
        second = luacheck_output([[OK % "c.lua"]], "Total: 0 warnings / 0 errors in 1 file")
        runs = [parallel.parse_luacheck(first, ["a.lua", "b.lua"]), parallel.parse_luacheck(second, ["c.lua"])]
        text, status = parallel.merge_luacheck(["a.lua", "b.lua", "c.lua"], runs)
        expected = luacheck_output([[OK % "a.lua"], warned, [OK % "c.lua"]], "Total: 1 warning / 0 errors in 3 files")
        self.assertEqual(text, expected)
        self.assertEqual(status, 1)

    def test_a_file_that_could_not_be_read_counts_as_luacheck_counts_it(self):
        fatal = ["Checking gone.lua%sI/O error" % (" " * 33), "", "    gone.lua: couldn't read: No such file", ""]
        first = luacheck_output([fatal], "Total: 0 warnings / 0 errors in 0 files, couldn't check 1 file")
        second = luacheck_output([[OK % "a.lua"]], "Total: 0 warnings / 0 errors in 1 file")
        runs = [parallel.parse_luacheck(first, ["gone.lua"]), parallel.parse_luacheck(second, ["a.lua"])]
        text, status = parallel.merge_luacheck(["a.lua", "gone.lua"], runs)
        self.assertEqual(
            text,
            luacheck_output([[OK % "a.lua"], fatal], "Total: 0 warnings / 0 errors in 1 file, couldn't check 1 file"),
        )
        self.assertEqual(status, 3)

    def test_colours_are_kept(self):
        run = parallel.parse_luacheck(
            luacheck_output([[OK % "a.lua"]], "Total: 0 warnings / 0 errors in 1 file", colored=True), ["a.lua"]
        )
        self.assertTrue(run.colored)
        text, status = parallel.merge_luacheck(["a.lua"], [run])
        self.assertTrue(
            text.endswith(
                "Total: \x1b[0m\x1b[0m\x1b[1m0\x1b[0m warnings / \x1b[0m\x1b[0m\x1b[1m0\x1b[0m errors in 1 file\n"
            )
        )
        self.assertEqual(status, 0)

    def test_a_critical_error_is_not_a_report(self):
        self.assertIsNone(parallel.parse_luacheck("Critical error: Couldn't find configuration file x\n", ["a.lua"]))

    def test_nothing_checked(self):
        text, status = parallel.merge_luacheck([], [])
        self.assertEqual((text, status), ("Total: 0 warnings / 0 errors in 0 files\n", 0))


@unittest.skipUnless(HAVE_LUACHECK, "luacheck is not installed")
class RealLuacheck(TreeCase):
    """luacheck itself on a generated tree: the parallel run prints byte for byte what one run prints."""

    def setUp(self):
        super().setUp()
        for number in range(20):
            self.write("a/ok%02d.lua" % number, "local x%d = 1\nreturn x%d\n" % (number, number))
        self.write("a/b/warn.lua", "local unused = 1\nglobal_thing = 2\n")
        self.write("a/b/syntax.lua", "local function f(\n")
        self.write("c/one.lua", "return 1\n")

    def test_byte_for_byte(self):
        for args in (["a", "c"], ["c", "a/b", "missing.lua"], ["c"]):
            for no_color in (False, True):
                with self.subTest(args=args, no_color=no_color):
                    env_args = ["env", "NO_COLOR=1"] if no_color else []
                    serial = self.run_in_root(*env_args, "luacheck", *args)
                    together = self.run_in_root(*env_args, sys.executable, "-I", SCRIPT, "luacheck", *args)
                    self.assertEqual(together, serial)
        self.assertEqual(serial[0], 0)
        self.assertEqual(self.run_in_root("luacheck", "a")[0], 2)

    def test_jobs_1_is_one_run(self):
        self.assertEqual(
            self.run_in_root(sys.executable, "-I", SCRIPT, "luacheck", "a", jobs="1"), self.run_in_root("luacheck", "a")
        )


# ---------------------------------------------------------------------------
# busted
# ---------------------------------------------------------------------------


class BustedParse(unittest.TestCase):
    def test_a_clean_file(self):
        counts = parallel.parse_busted(
            parallel.Result(0, "+++\n3 successes / 0 failures / 0 errors / 0 pending : 0.01 seconds\n")
        )
        self.assertEqual((counts.successes, counts.failures, counts.errors, counts.pending), (3, 0, 0, 0))
        self.assertTrue(counts.clean)

    def test_anything_beyond_the_progress_line_is_shown(self):
        printed = "hello\n+\n1 success / 0 failures / 0 errors / 0 pending : 0.0 seconds\n"
        self.assertFalse(parallel.parse_busted(parallel.Result(0, printed)).clean)
        pending = (
            "+.\n1 success / 0 failures / 0 errors / 1 pending : 0.0 seconds\n\nPending -> x_spec.lua @ 3\nlater\n"
        )
        counts = parallel.parse_busted(parallel.Result(0, pending))
        self.assertEqual((counts.pending, counts.clean), (1, False))

    def test_failures_and_errors_count(self):
        text = "-*+\n1 success / 1 failure / 1 error / 0 pending : 0.0 seconds\n\nFailure -> x_spec.lua @ 2\n"
        counts = parallel.parse_busted(parallel.Result(1, text))
        self.assertEqual((counts.successes, counts.failures, counts.errors, counts.clean), (1, 1, 1, False))

    def test_a_run_without_a_summary_is_an_error(self):
        counts = parallel.parse_busted(parallel.Result(127, "busted: command not found\n"))
        self.assertEqual((counts.errors, counts.clean), (1, False))
        counts = parallel.parse_busted(
            parallel.Result(1, "+\n1 success / 0 failures / 0 errors / 0 pending : 0.0 seconds\n")
        )
        self.assertEqual((counts.errors, counts.clean), (1, False))

    def test_summary_in_busteds_words(self):
        self.assertEqual(
            parallel.busted_summary(1, 1, 1, 1, 0.5), "1 success / 1 failure / 1 error / 1 pending : 0.5 seconds"
        )
        self.assertEqual(
            parallel.busted_summary(0, 2, 0, 0, 4.2526831),
            "0 successes / 2 failures / 0 errors / 0 pending : 4.252683 seconds",
        )
        self.assertEqual(parallel.busted_seconds(3.0), "3.0")


class BustedFiles(TreeCase):
    def test_spec_files_like_busted(self):
        for path in ("spec/b_spec.lua", "spec/a_spec.lua", "spec/sub/c_spec.lua", "spec/helper.lua", "spec/x_spec.txt"):
            self.write(path)
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(self.root)
        self.assertEqual(
            parallel.busted_files(["spec", "spec/helper.lua"]),
            ["spec/a_spec.lua", "spec/b_spec.lua", "spec/sub/c_spec.lua", "spec/helper.lua"],
        )


@unittest.skipUnless(HAVE_BUSTED, "busted is not installed")
class RealBusted(TreeCase):
    def setUp(self):
        super().setUp()
        self.write("spec/a_spec.lua", 'describe("a", function() it("passes", function() end) end)\n')
        self.write(
            "spec/d_spec.lua", 'describe("d", function() it("one", function() end) it("two", function() end) end)\n'
        )

    def summary_counts(self, text):
        return parallel.BUSTED_SUMMARY_RE.findall(text)[-1]

    def test_passing(self):
        code, out, _ = self.run_in_root(sys.executable, "-I", SCRIPT, "busted", "spec")
        self.assertEqual(code, 0)
        self.assertEqual(out.count("\n"), 1, out)  # nothing but the total
        self.assertEqual(self.summary_counts(out), self.summary_counts(self.run_in_root("busted", "spec")[1]))

    def test_failing(self):
        self.write(
            "spec/b_spec.lua",
            'describe("b", function()\n  it("fails", function() assert.are.equal(1, 2) end)\n'
            '  it("errors", function() error("boom") end)\n  pending("later")\nend)\n',
        )
        self.write("spec/sub/c_spec.lua", 'describe("c", function( it(\n')
        serial = self.run_in_root("busted", "spec")
        code, out, _ = self.run_in_root(sys.executable, "-I", SCRIPT, "busted", "spec")
        self.assertEqual((code, serial[0]), (1, 1))
        self.assertEqual(self.summary_counts(out), self.summary_counts(serial[1]))
        self.assertEqual(self.summary_counts(out), ("3", "1", "2", "1"))
        self.assertIn("== busted spec/b_spec.lua (exit 1)", out)
        self.assertIn("== busted spec/sub/c_spec.lua (exit 1)", out)
        self.assertLess(out.index("spec/b_spec.lua (exit"), out.index("spec/sub/c_spec.lua (exit"))
        self.assertNotIn("a_spec.lua", out)


# ---------------------------------------------------------------------------
# unittest
# ---------------------------------------------------------------------------


def unittest_output(progress, ran, status):
    return "%s\n%s\nRan %d test%s in 0.001s\n\n%s\n" % (
        progress,
        parallel.UNITTEST_SEPARATOR,
        ran,
        "" if ran == 1 else "s",
        status,
    )


class UnittestParse(unittest.TestCase):
    def test_counts(self):
        module = parallel.parse_unittest(
            parallel.Result(
                1, unittest_output("FE.sx", 5, "FAILED (failures=1, errors=1, skipped=1, expected failures=1)")
            )
        )
        self.assertEqual(
            (module.ran, module.failures, module.errors, module.skipped, module.expected_failures, module.passed),
            (5, 1, 1, 1, 1, False),
        )
        module = parallel.parse_unittest(parallel.Result(0, unittest_output("..s", 3, "OK (skipped=1)")))
        self.assertEqual((module.ran, module.skipped, module.passed, module.clean), (3, 1, True, True))

    def test_extra_output_is_shown(self):
        module = parallel.parse_unittest(parallel.Result(0, unittest_output("..\nreport\n..", 4, "OK")))
        self.assertEqual((module.passed, module.clean), (True, False))

    def test_a_module_without_tests_is_no_failure(self):
        module = parallel.parse_unittest(parallel.Result(5, unittest_output("", 0, "NO TESTS RAN")))
        self.assertEqual((module.ran, module.passed), (0, True))

    def test_a_run_without_a_summary_is_an_error(self):
        module = parallel.parse_unittest(parallel.Result(-9, ""))
        self.assertEqual((module.errors, module.passed), (1, False))

    def test_summary_in_unittests_words(self):
        total = parallel.UnittestModule(ran=7, skipped=2, expected_failures=1, passed=True)
        self.assertTrue(
            parallel.unittest_summary(total, 1.5).endswith(
                "Ran 7 tests in 1.500s\n\nOK (skipped=2, expected failures=1)\n"
            )
        )
        total = parallel.UnittestModule(ran=1, failures=1, unexpected_successes=1, passed=False)
        self.assertTrue(
            parallel.unittest_summary(total, 0).endswith(
                "Ran 1 test in 0.000s\n\nFAILED (failures=1, unexpected successes=1)\n"
            )
        )
        self.assertTrue(parallel.unittest_summary(parallel.UnittestModule(passed=True), 0).endswith("\nNO TESTS RAN\n"))


class RealUnittest(TreeCase):
    def setUp(self):
        super().setUp()
        self.write(
            "t/test_a.py",
            "import unittest\nclass A(unittest.TestCase):\n    def test_ok(self): pass\n"
            "    @unittest.skip('no')\n    def test_skip(self): pass\n",
        )
        self.write("t/test_empty.py", "")

    def last_line(self, text):
        return text.strip().splitlines()[-1]

    def run_both(self):
        serial = self.run_in_root(sys.executable, "-B", "-m", "unittest", "discover", "-s", "t")
        together = self.run_in_root(sys.executable, "-I", SCRIPT, "unittest", "t")
        return serial, together

    def test_passing(self):
        serial, together = self.run_both()
        self.assertEqual((together[0], serial[0]), (0, 0))
        self.assertEqual(self.last_line(together[1]), self.last_line(serial[2]))
        self.assertEqual(self.last_line(together[1]), "OK (skipped=1)")
        self.assertNotIn("==", together[1])

    def test_failing(self):
        self.write(
            "t/test_b.py", "import unittest\nclass B(unittest.TestCase):\n    def test_no(self): self.fail('x')\n"
        )
        self.write("t/test_c.py", "import no_such_module_456\n")
        serial, together = self.run_both()
        self.assertEqual((together[0], serial[0]), (1, 1))
        self.assertEqual(self.last_line(together[1]), self.last_line(serial[2]))
        self.assertEqual(self.last_line(together[1]), "FAILED (failures=1, errors=1, skipped=1)")
        self.assertLess(together[1].index("== unittest test_b.py"), together[1].index("== unittest test_c.py"))

    def test_no_tests(self):
        os.remove(os.path.join(self.root, "t", "test_a.py"))
        serial, together = self.run_both()
        self.assertEqual((together[0], serial[0]), (5, 5))
        self.assertEqual(self.last_line(together[1]), "NO TESTS RAN")


if __name__ == "__main__":
    unittest.main()
