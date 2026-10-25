"""Unit tests for tools/devctl.py's `wait`: when a queued command counts as done (issue #239).

No server is contacted: devctl.call answers from a scripted bridge loop and the clock is a fake
one, so a minute of waiting takes no time.

Run: python3 -m unittest discover -s tools/tests -v
"""

import argparse
import contextlib
import io
import os
import sys
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, TOOLS)

import devctl  # noqa: E402

EPOCH = 1_761_350_400.0  # the server's clock when a test begins (unix seconds)
STOP = {"id": 12, "type": "set_property", "name": "Dev Server", "value": ""}


class Clock:
    """time.monotonic, time.sleep and time.time for devctl; only sleep moves it."""

    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds

    def time(self):
        return EPOCH + self.now


class Bridge:
    """The dev server's /status while a bridge's loop polls it every POLL_S seconds.

    The loop polls at first_poll, first_poll + 3, ... up to polls_until (None: for ever), and
    last_contact (seconds on the test clock, None: never) is its latest request before the test.
    reports_at is when it reports the command done (None: never), as a loop with the fix of issue
    #239 does even for a command that stops it."""

    def __init__(self, clock, command, last_contact=-2.0, first_poll=1.0, polls_until=None, reports_at=None):
        self.clock, self.command = clock, command
        self.last_contact, self.first_poll, self.polls_until = last_contact, first_poll, polls_until
        self.reports_at = reports_at

    def last_seen(self, now):
        seen = self.last_contact
        poll = self.first_poll
        while poll <= now and (self.polls_until is None or poll <= self.polls_until):
            seen = poll
            poll += devctl.POLL_S
        return None if seen is None else EPOCH + seen

    def status(self, args, method, path, body=None):
        if (method, path) != ("GET", "/status"):
            raise AssertionError("wait asked for %s %s" % (method, path))
        now = self.clock.now
        done = self.reports_at is not None and now >= self.reports_at
        return {
            "last_seen": self.last_seen(now),
            "server_time": EPOCH + now,
            "pending_commands": [] if done else [dict(self.command)],
            "done_commands": [self.command["id"]] if done else [],
            "last_done_id": self.command["id"] if done else None,
            "properties": {"Dev Server": "", "Status": "Paired"},
        }


class WaitTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()

    def wait(self, bridge, timeout=60):
        args = argparse.Namespace(id=bridge.command["id"], timeout=timeout, server="http://192.0.2.7:8080", token="t")
        out, err = io.StringIO(), io.StringIO()
        with (
            mock.patch.object(devctl, "call", bridge.status),
            mock.patch.object(devctl, "time", self.clock),
            contextlib.redirect_stdout(out),
            contextlib.redirect_stderr(err),
        ):
            code = devctl.cmd_wait(args)
        return code, out.getvalue(), err.getvalue()

    def test_a_loop_that_reports_ends_the_wait_with_its_properties(self):
        code, out, err = self.wait(Bridge(self.clock, STOP, polls_until=1.0, reports_at=1.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertRegex(out, r"\n  Status += Paired\n")
        self.assertEqual("", err)
        self.assertEqual(1.0, self.clock.now)

    def test_a_stop_an_older_loop_never_reports_is_done_once_the_bridge_is_quiet(self):
        code, out, err = self.wait(Bridge(self.clock, STOP, polls_until=1.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertEqual("", out, "no properties: the last report predates the command")
        self.assertIn("#12 set 'Dev Server' = '' treated as done", err)
        self.assertIn("silent for 20s", err)
        self.assertIn("issue #239", err)
        self.assertEqual(21.0, self.clock.now, "QUIET_S after the bridge's last poll")

    def test_a_move_to_another_server_counts_the_same(self):
        move = dict(STOP, id=13, value="198.51.100.20:8080")
        code, _, err = self.wait(Bridge(self.clock, move, polls_until=4.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertIn("#13 set 'Dev Server' = '198.51.100.20:8080' treated as done", err)
        self.assertEqual(24.0, self.clock.now)

    def test_a_stop_taken_between_the_set_and_the_wait_counts(self):
        # devctl.py wait $(devctl.py set "Dev Server" ""): the bridge may poll in between.
        code, _, err = self.wait(Bridge(self.clock, STOP, last_contact=-0.4, polls_until=-1.0))
        self.assertEqual(devctl.EXIT_OK, code)
        self.assertIn("treated as done", err)
        self.assertEqual(20.0, self.clock.now)

    def test_a_wait_begun_after_the_bridge_went_quiet_times_out_with_a_hint(self):
        # The loop was gone before the wait: nothing says it ever took the command.
        code, out, err = self.wait(Bridge(self.clock, STOP, last_contact=-30.0, polls_until=-1.0))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertEqual("", out)
        self.assertIn("timed out after 60s waiting for command 12 (still pending; the bridge has been silent", err)
        self.assertIn("issue #239", err)
        self.assertNotIn("treated as done", err)

    def test_a_bridge_never_seen_times_out(self):
        code, _, err = self.wait(Bridge(self.clock, STOP, last_contact=None, first_poll=1e9), timeout=30)
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertIn("the bridge has not been in touch since the server started", err)

    def test_a_bridge_that_keeps_polling_is_not_quiet(self):
        code, _, err = self.wait(Bridge(self.clock, STOP))
        self.assertEqual(devctl.EXIT_TIMEOUT, code)
        self.assertEqual("timed out after 60s waiting for command 12 (still pending)\n", err)

    def test_any_other_command_waits_for_its_report(self):
        for command in (
            {"id": 14, "type": "execute", "command": "Connection Test", "params": {"Target": "Bridge"}},
            {"id": 15, "type": "set_property", "name": "Stream Timeout (s)", "value": "60"},
            {"id": 16, "type": "reload"},
        ):
            with self.subTest(command=command["id"]):
                self.clock = Clock()
                code, _, err = self.wait(Bridge(self.clock, command, polls_until=1.0))
                self.assertEqual(devctl.EXIT_TIMEOUT, code)
                self.assertEqual("timed out after 60s waiting for command %d (still pending)\n" % command["id"], err)

    def test_which_commands_change_dev_server(self):
        for name in ("Dev Server", "Dev  Server", "Dev\tServer"):
            with self.subTest(name=name):
                self.assertTrue(devctl.changes_dev_server(dict(STOP, name=name)))
        for command in (
            dict(STOP, name="Dev Servers"),
            dict(STOP, name="dev server"),
            dict(STOP, name="Diagnostic Server"),
            {"id": 1, "type": "execute", "command": "Dev Server"},
            {"id": 2, "type": "reload"},
            None,
        ):
            with self.subTest(command=command):
                self.assertFalse(devctl.changes_dev_server(command))


if __name__ == "__main__":
    unittest.main()
