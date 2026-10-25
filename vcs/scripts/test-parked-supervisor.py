#!/usr/bin/env python3
"""Exercise the real supervisor's parked wait under a PTY, without a server or fixed port."""

import errno
import os
import pathlib
import pty
import signal
import tempfile
import time
import unittest


SUPERVISOR = pathlib.Path(__file__).resolve().parents[1] / "crates/workroomd/src/run_supervisor.sh"


class ParkedSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="parked-supervisor-")
        root = pathlib.Path(self.directory.name)
        self.status = root / "status"
        self.log = root / "sleeps"
        self.marker = root / "signalled"
        sleeper = root / "sleep"
        sleeper.write_text("""#!/bin/sh
printf '%s %s\\n' "$$" "$*" >> "$PARK_SLEEP_LOG"
if [ -n "${PARK_RACE_MARKER:-}" ] && [ ! -e "$PARK_RACE_MARKER" ]; then
  : > "$PARK_RACE_MARKER"
  kill -USR1 "$PPID"
fi
exec /bin/sleep "$@"
""")
        sleeper.chmod(0o700)
        self.environment = dict(os.environ, PATH=f"{root}:/usr/bin:/bin", PARK_SLEEP_LOG=str(self.log))
        self.pid = None
        self.fd = None
        self.reaped = False
        self.output = bytearray()

    def tearDown(self):
        if self.pid is not None:
            try:
                os.killpg(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            if not self.reaped:
                os.waitpid(self.pid, 0)
        if self.fd is not None:
            os.close(self.fd)
        self.directory.cleanup()

    def start(self, signal_from_waiter=False):
        if signal_from_waiter:
            self.environment["PARK_RACE_MARKER"] = str(self.marker)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            flags = ["-x"] if os.environ.get("WORKROOM_SUPERVISOR_TRACE") else []
            os.execve("/bin/sh", ["/bin/sh", *flags, str(SUPERVISOR), str(self.status),
                                 "/bin/sh", "-c", "exit 0"], self.environment)
        os.set_blocking(self.fd, False)

    def wait_for(self, condition, seconds=5, poll_interval=0.01):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            # Repeated short runs must not fill the PTY and stall on their status prompt.
            try:
                if self.fd is not None:
                    while chunk := os.read(self.fd, 4096):
                        self.output.extend(chunk)
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO):
                    raise
            if condition():
                return True
            time.sleep(poll_interval)
        return condition()

    def parked(self, launch):
        try:
            return self.status.read_text().strip() == f"exited 0 {launch}"
        except FileNotFoundError:
            return False

    def sleeps(self):
        try:
            return [int(line.split()[0]) for line in self.log.read_text().splitlines()]
        except FileNotFoundError:
            return []

    @staticmethod
    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def quit_and_check_waiters(self):
        os.kill(self.pid, signal.SIGTERM)
        self.check_exit_and_waiters()

    def check_exit_and_waiters(self):
        def exited():
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.reaped = True
                self.assertEqual(os.waitstatus_to_exitcode(status), 0)
            return bool(pid)

        self.assertTrue(self.wait_for(exited), "parked supervisor ignored Quit")
        self.assertTrue(self.wait_for(lambda: not any(map(self.alive, self.sleeps()))),
                        "a parked wait process outlived Quit")
        self.assertNotIn(b"Killed", self.output, "waiter cleanup leaked into the terminal")

    def test_idle_park_keeps_sleep_process_launches_bounded(self):
        self.start()
        self.assertTrue(self.wait_for(lambda: self.parked(1) and self.sleeps()))
        before = self.sleeps()
        started = time.monotonic()
        time.sleep(0.75)
        elapsed = time.monotonic() - started
        # The zero-wakeup waiter lost trapped controls on macOS. The approved timed rollback
        # deliberately restores polling; retain a bound so a busy loop cannot replace it.
        # Account for an overslept observation window on a busy test host (normally four).
        self.assertLessEqual(len(self.sleeps()) - len(before), int(elapsed / 0.2) + 1,
                             "idle parking spawned too many sleep processes")
        self.quit_and_check_waiters()

    def test_parked_restart_and_quit_remain_responsive(self):
        self.start()
        self.assertTrue(self.wait_for(lambda: self.parked(1) and self.sleeps()))
        # Restart immediately after each distinct exited generation. A trapped control can arrive
        # as the shell enters its parked wait; a second control must not be needed to wake it.
        for launch in range(2, 32):
            os.kill(self.pid, signal.SIGUSR1)
            reached = self.wait_for(lambda: self.parked(launch), poll_interval=0.001)
            self.assertTrue(reached,
                            f"restart {launch}: status={self.status.read_text()!r}, output={self.output[-4000:]!r}")
        self.quit_and_check_waiters()

    def test_a_control_from_the_waiter_startup_is_not_lost(self):
        self.start(signal_from_waiter=True)
        self.assertTrue(self.wait_for(lambda: self.parked(2) and len(self.sleeps()) >= 2),
                        "a restart during wait startup was lost")
        self.quit_and_check_waiters()

    def test_pty_hangup_ends_the_parked_supervisor_and_waiter(self):
        self.start()
        self.assertTrue(self.wait_for(lambda: self.parked(1) and self.sleeps()))
        os.close(self.fd)
        self.fd = None
        self.check_exit_and_waiters()


if __name__ == "__main__":
    unittest.main()
