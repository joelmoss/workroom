#!/usr/bin/env python3
"""Tests for gui-lock.py. Standard library only; runs on macOS and Linux alike, since flock(2)
behaves the same on both.

    python3 macapp/Scripts/gui-lock_test.py

Each case runs the real helper as a subprocess against a throwaway WR_GUI_LOCK_DIR. The commands
it wraps are tiny Python scripts that drop a `started` marker and then block until the test drops a
`release` marker, so every ordering claim below ("B has not started while A holds the lock") is
checked against events the test controls, not against sleeps racing a loaded machine. The one
timing constant is NOT_WITHIN: how long a run must stay blocked to count as blocked.
"""

import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gui-lock.py")
NOT_WITHIN = 1.0
PROMPTLY = 10.0

# started -> wait for release -> exit with the requested status. A case's cleanup releases each
# run, kills its helper and then deletes the case's directory, which can beat a blocker the killed
# helper orphaned to its next look at the release marker; a gone directory releases it too, or it
# would poll forever.
BLOCKER = """
import os, sys, time
marker, release, status = sys.argv[1], sys.argv[2], int(sys.argv[3])
open(marker, "w").close()
while not os.path.exists(release) and os.path.isdir(os.path.dirname(release)):
    time.sleep(0.02)
sys.exit(status)
"""


class Run:
    """One gui-lock.py invocation wrapping a BLOCKER."""

    def __init__(self, case, name, mode, status=0, env=None, command=None, label=None,
                 options=()):
        self.started = os.path.join(case.tmp, name + ".started")
        self.release_marker = os.path.join(case.tmp, name + ".release")
        if command is None:
            command = [sys.executable, "-c", BLOCKER, self.started, self.release_marker,
                       str(status)]
        args = [sys.executable, HELPER, mode] + list(options)
        if label is not None:
            args += ["--label", label]
        args += ["--"] + command
        environment = dict(case.env)
        environment.update(env or {})
        self.process = subprocess.Popen(
            args, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        case.addCleanup(self.kill)

    def has_started(self):
        return os.path.exists(self.started)

    def wait_started(self, timeout=PROMPTLY):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.has_started():
                return True
            time.sleep(0.02)
        return False

    def stays_blocked(self, seconds=NOT_WITHIN):
        return not self.wait_started(seconds)

    def release(self):
        open(self.release_marker, "w").close()

    def finish_after_release(self):
        self.release()
        return self.finish()[0]

    def finish(self, timeout=PROMPTLY):
        out, err = self.process.communicate(timeout=timeout)
        return self.process.returncode, out, err

    def kill(self):
        self.release()
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        for stream in (self.process.stdout, self.process.stderr):
            if stream is not None:
                stream.close()


class GuiLockTests(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gui-lock-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env["WR_GUI_LOCK_DIR"] = os.path.join(self.tmp, "locks")
        for name in ("WR_GUI_LOCK", "WR_GUI_LOCK_TIMEOUT"):
            self.env.pop(name, None)

    def status(self):
        result = subprocess.run(
            [sys.executable, HELPER, "status"], env=self.env, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, universal_newlines=True)
        return result.returncode, result.stdout

    def test_exclusive_runs_one_at_a_time(self):
        first = Run(self, "first", "exclusive")
        self.assertTrue(first.wait_started())
        second = Run(self, "second", "exclusive")
        self.assertTrue(second.stays_blocked(), "a second UI-test run started under the first")
        first.release()
        self.assertEqual(first.finish()[0], 0)
        self.assertTrue(second.wait_started(), "the second run never got the session")
        second.release()
        code, _, err = second.finish()
        self.assertEqual(code, 0)
        self.assertIn("waiting for this Mac's GUI session", err)

    def test_shared_runs_overlap(self):
        first = Run(self, "first", "shared")
        second = Run(self, "second", "shared")
        self.assertTrue(first.wait_started())
        self.assertTrue(second.wait_started(), "two unit-test runs must not exclude each other")
        first.release()
        second.release()
        self.assertEqual(first.finish()[0], 0)
        self.assertEqual(second.finish()[0], 0)

    def test_exclusive_waits_for_shared_holders(self):
        unit = Run(self, "unit", "shared")
        self.assertTrue(unit.wait_started())
        ui = Run(self, "ui", "exclusive")
        self.assertTrue(ui.stays_blocked(), "a UI-test run started while a unit run held a share")
        unit.release()
        self.assertTrue(ui.wait_started())

    def test_shared_waits_for_exclusive_holder(self):
        ui = Run(self, "ui", "exclusive")
        self.assertTrue(ui.wait_started())
        unit = Run(self, "unit", "shared")
        self.assertTrue(unit.stays_blocked(), "a unit run started under a UI-test run")
        ui.release()
        self.assertTrue(unit.wait_started())

    def test_a_queued_exclusive_run_goes_before_later_shared_runs(self):
        early = Run(self, "early", "shared")
        self.assertTrue(early.wait_started())
        ui = Run(self, "ui", "exclusive", label="app-uitest /work/brave-otter")
        # Queued: it has passed the turnstile and is waiting out `early`.
        deadline = time.time() + PROMPTLY
        while time.time() < deadline and "queued" not in self.status()[1]:
            time.sleep(0.05)
        self.assertIn("queued    app-uitest /work/brave-otter", self.status()[1])
        late = Run(self, "late", "shared")
        self.assertTrue(late.stays_blocked(), "a unit run jumped a queued UI-test run")
        early.release()
        self.assertTrue(ui.wait_started())
        self.assertTrue(late.stays_blocked(), "a unit run started while the UI-test run ran")
        ui.release()
        self.assertTrue(late.wait_started())

    def test_a_killed_holder_releases_the_session(self):
        first = Run(self, "first", "exclusive")
        self.assertTrue(first.wait_started())
        first.process.send_signal(signal.SIGKILL)
        first.process.wait()
        second = Run(self, "second", "exclusive")
        self.assertTrue(second.wait_started(), "a SIGKILLed holder kept the session locked")

    def test_a_process_the_command_leaves_behind_does_not_hold_the_lock(self):
        # The command exits at once but leaves a grandchild running, as a session helper that
        # outlives a test would. The lock must go with the helper, not with that grandchild.
        leftover = os.path.join(self.tmp, "leftover.pid")
        # Its stdio goes to /dev/null only so that `finish()` sees EOF on this test's own pipes;
        # the lock file descriptors are what is under test, and those it would inherit if it could.
        spawn = ("import subprocess, sys; "
                 "p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], "
                 "stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=False); "
                 "open(sys.argv[1], 'w').write(str(p.pid))")
        first = Run(self, "first", "exclusive", command=[sys.executable, "-c", spawn, leftover])
        self.assertEqual(first.finish()[0], 0)
        with open(leftover) as handle:
            pid = int(handle.read())
        self.addCleanup(lambda: os.kill(pid, signal.SIGKILL))
        second = Run(self, "second", "exclusive")
        self.assertTrue(second.wait_started(), "the command's leftover child inherited the lock")

    def test_exit_status_is_the_commands(self):
        self.assertEqual(Run(self, "fails", "shared", status=7).finish_after_release(), 7)

    def test_a_command_killed_by_a_signal_reports_128_plus_it(self):
        run = Run(self, "killed", "shared",
                  command=[sys.executable, "-c", "import os, signal; os.kill(os.getpid(), 15)"])
        self.assertEqual(run.finish()[0], 128 + signal.SIGTERM)

    def test_sigterm_to_the_helper_reaches_the_command_and_frees_the_session(self):
        first = Run(self, "first", "exclusive")
        self.assertTrue(first.wait_started())
        first.process.send_signal(signal.SIGTERM)
        code, _, _ = first.finish()
        self.assertEqual(code, 128 + signal.SIGTERM, "the command should have died of SIGTERM")
        second = Run(self, "second", "exclusive")
        self.assertTrue(second.wait_started())

    def test_the_command_can_still_be_interrupted(self):
        # The helper waits out Ctrl-C itself while its command runs. Had it done so with SIG_IGN,
        # exec would have carried the ignore into the command, and xcodebuild would shrug off
        # Ctrl-C. Python leaves an inherited SIG_IGN in place at startup, which makes it visible.
        probe = ("import signal, sys; "
                 "sys.exit(3 if signal.getsignal(signal.SIGINT) is signal.SIG_IGN else 0)")
        run = Run(self, "probe", "exclusive", command=[sys.executable, "-c", probe])
        self.assertEqual(run.finish()[0], 0, "the command inherited an ignored SIGINT")

    def test_timeout_gives_up_with_ex_tempfail(self):
        holder = Run(self, "holder", "exclusive")
        self.assertTrue(holder.wait_started())
        started = time.time()
        waiter = Run(self, "waiter", "shared", env={"WR_GUI_LOCK_TIMEOUT": "0.3"})
        code, _, err = waiter.finish()
        self.assertEqual(code, 75)
        self.assertLess(time.time() - started, PROMPTLY)
        self.assertIn("gave up", err)
        self.assertFalse(waiter.has_started())

    def test_off_bypasses_the_lock(self):
        holder = Run(self, "holder", "exclusive")
        self.assertTrue(holder.wait_started())
        bypass = Run(self, "bypass", "exclusive", env={"WR_GUI_LOCK": "off"})
        self.assertTrue(bypass.wait_started(), "WR_GUI_LOCK=off still waited")

    def test_an_unusable_lock_directory_runs_the_command_unlocked(self):
        # A coordination aid must not turn a HOME it cannot write into a failed test run.
        blocker = os.path.join(self.tmp, "not-a-directory")
        open(blocker, "w").close()
        run = Run(self, "unlocked", "exclusive",
                  env={"WR_GUI_LOCK_DIR": os.path.join(blocker, "locks")}, status=3)
        self.assertTrue(run.wait_started(), "the command never ran")
        run.release()
        code, _, err = run.finish()
        self.assertEqual(code, 3)
        self.assertIn("running without it", err)

    def test_status_reports_holders_and_exits_1_only_for_exclusive(self):
        self.assertEqual(self.status(), (0, "gui-lock: free\n"))
        unit = Run(self, "unit", "shared", label="app-test /work/quiet-fern")
        self.assertTrue(unit.wait_started())
        code, out = self.status()
        self.assertEqual(code, 0)
        self.assertIn("shared    app-test /work/quiet-fern", out)
        unit.release()
        unit.finish()
        ui = Run(self, "ui", "exclusive", label="app-uitest /work/brave-otter")
        self.assertTrue(ui.wait_started())
        code, out = self.status()
        self.assertEqual(code, 1)
        self.assertIn("exclusive app-uitest /work/brave-otter", out)
        ui.release()
        ui.finish()
        self.assertEqual(self.status(), (0, "gui-lock: free\n"))

    def test_a_record_left_by_a_dead_holder_is_ignored(self):
        holders = os.path.join(self.env["WR_GUI_LOCK_DIR"], "gui.holders")
        os.makedirs(holders)
        dead = subprocess.Popen([sys.executable, "-c", "pass"])
        dead.wait()
        with open(os.path.join(holders, str(dead.pid)), "w") as record:
            record.write("exclusive\t0\tgone\n")
        self.assertEqual(self.status(), (0, "gui-lock: free\n"))
        self.assertFalse(os.path.exists(os.path.join(holders, str(dead.pid))))

    def test_usage_errors_exit_2(self):
        for args in ([], ["sometimes", "--", "true"], ["shared", "true"], ["shared", "--"],
                     ["exclusive", "--label"]):
            result = subprocess.run(
                [sys.executable, HELPER] + args, env=self.env, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 2, args)


# Records the slot it was given, then blocks like BLOCKER.
SLOT_BLOCKER = """
import os, sys, time
marker, release = sys.argv[1], sys.argv[2]
with open(marker, "w") as handle:
    handle.write(os.environ.get("WR_VM_SLOT", ""))
while not os.path.exists(release) and os.path.isdir(os.path.dirname(release)):
    time.sleep(0.02)
"""


class VmSlotTests(unittest.TestCase):
    """`vm-slot`: a counting lock over this Mac's two macOS guests (make app-uitest-vm)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gui-lock-vm-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env["WR_VM_LOCK_DIR"] = os.path.join(self.tmp, "vm-locks")
        self.env["WR_GUI_LOCK_DIR"] = os.path.join(self.tmp, "gui-locks")
        for name in ("WR_GUI_LOCK", "WR_GUI_LOCK_TIMEOUT", "WR_VM_LOCK_TIMEOUT", "WR_VM_SLOT"):
            self.env.pop(name, None)

    def guest(self, name, slots=2, env=None, label=None):
        started = os.path.join(self.tmp, name + ".started")
        release = os.path.join(self.tmp, name + ".release")
        return Run(self, name, "vm-slot", env=env, label=label,
                   options=["--slots", str(slots)],
                   command=[sys.executable, "-c", SLOT_BLOCKER, started, release])

    def slot_of(self, run):
        with open(run.started) as handle:
            return handle.read()

    def vm_status(self, slots=2):
        result = subprocess.run(
            [sys.executable, HELPER, "vm-status", "--slots", str(slots)], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        return result.returncode, result.stdout

    def test_two_guests_run_at_once_and_a_third_waits(self):
        first = self.guest("first")
        second = self.guest("second")
        self.assertTrue(first.wait_started())
        self.assertTrue(second.wait_started(), "two guests must not exclude each other")
        self.assertEqual({self.slot_of(first), self.slot_of(second)}, {"1", "2"})
        third = self.guest("third")
        self.assertTrue(third.stays_blocked(), "a third guest started while two ran")
        freed = self.slot_of(second)
        second.release()
        self.assertEqual(second.finish()[0], 0)
        self.assertTrue(third.wait_started(), "the third guest never got the freed slot")
        self.assertEqual(self.slot_of(third), freed, "the third guest must take the freed slot")
        first.release()
        third.release()
        self.assertEqual(first.finish()[0], 0)
        code, _, err = third.finish()
        self.assertEqual(code, 0)
        self.assertIn("waiting for a VM slot", err)

    def test_slots_is_the_count(self):
        only = self.guest("only", slots=1)
        self.assertTrue(only.wait_started())
        self.assertEqual(self.slot_of(only), "1")
        next_run = self.guest("next", slots=1)
        self.assertTrue(next_run.stays_blocked(), "--slots 1 let a second guest in")
        only.release()
        self.assertTrue(next_run.wait_started())

    def test_an_unusable_lock_directory_fails_closed(self):
        blocker = os.path.join(self.tmp, "not-a-directory")
        open(blocker, "w").close()
        run = self.guest("closed", env={"WR_VM_LOCK_DIR": os.path.join(blocker, "locks")})
        code, _, err = run.finish()
        self.assertEqual(code, 75)
        self.assertFalse(run.has_started(), "a guest ran without the slot lock")
        self.assertIn("cannot use the VM slot lock", err)

    def test_gui_lock_off_does_not_bypass_the_slots(self):
        first = self.guest("first", slots=1)
        self.assertTrue(first.wait_started())
        second = self.guest("second", slots=1, env={"WR_GUI_LOCK": "off"})
        self.assertTrue(second.stays_blocked(), "WR_GUI_LOCK=off let a guest past a full slot")

    def test_a_killed_holder_frees_its_slot(self):
        first = self.guest("first", slots=1)
        self.assertTrue(first.wait_started())
        first.process.send_signal(signal.SIGKILL)
        first.process.wait()
        second = self.guest("second", slots=1)
        self.assertTrue(second.wait_started(), "a SIGKILLed holder kept its slot")

    def test_sigterm_reaches_the_command_and_frees_the_slot(self):
        first = self.guest("first", slots=1)
        self.assertTrue(first.wait_started())
        first.process.send_signal(signal.SIGTERM)
        code, _, _ = first.finish()
        self.assertEqual(code, 128 + signal.SIGTERM, "the command should have died of SIGTERM")
        second = self.guest("second", slots=1)
        self.assertTrue(second.wait_started())

    def test_a_waiting_run_interrupted_exits_without_running(self):
        holder = self.guest("holder", slots=1)
        self.assertTrue(holder.wait_started())
        waiter = self.guest("waiter", slots=1)
        self.assertTrue(waiter.stays_blocked())
        waiter.process.send_signal(signal.SIGINT)
        self.assertEqual(waiter.finish()[0], 128 + signal.SIGINT)
        self.assertFalse(waiter.has_started())

    def test_timeout_gives_up_with_ex_tempfail(self):
        holder = self.guest("holder", slots=1)
        self.assertTrue(holder.wait_started())
        waiter = self.guest("waiter", slots=1, env={"WR_VM_LOCK_TIMEOUT": "0.3"})
        code, _, err = waiter.finish()
        self.assertEqual(code, 75)
        self.assertIn("gave up", err)
        self.assertFalse(waiter.has_started())

    def test_the_slots_are_apart_from_the_gui_session(self):
        ui = Run(self, "ui", "exclusive")
        self.assertTrue(ui.wait_started())
        guest = self.guest("guest")
        self.assertTrue(guest.wait_started(), "a guest waited on this Mac's GUI session")

    def test_vm_status_names_holders_and_exits_1_when_full(self):
        self.assertEqual(self.vm_status(), (0, "gui-lock: 0 of 2 VM slots in use\n"))
        first = self.guest("first", label="app-uitest-vm /work/brave-otter")
        self.assertTrue(first.wait_started())
        code, out = self.vm_status()
        self.assertEqual(code, 0)
        self.assertIn("1 of 2 VM slots in use", out)
        self.assertIn("slot 1    app-uitest-vm /work/brave-otter", out)
        second = self.guest("second", label="app-uitest-vm /work/quiet-fern")
        self.assertTrue(second.wait_started())
        code, out = self.vm_status()
        self.assertEqual(code, 1)
        self.assertIn("slot 2    app-uitest-vm /work/quiet-fern", out)

    def test_bad_slot_counts_are_usage_errors(self):
        for args in (["vm-slot", "--slots", "0", "--", "true"],
                     ["vm-slot", "--slots", "two", "--", "true"],
                     ["vm-slot", "--slots"], ["vm-status", "extra"]):
            result = subprocess.run(
                [sys.executable, HELPER] + args, env=self.env, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE)
            self.assertEqual(result.returncode, 2, args)


class CheckoutLockTests(unittest.TestCase):
    """`checkout`: one `make app-*` build or test at a time per checkout, since they share its
    macapp/DerivedData (make's SHELL for those targets, macapp/Scripts/checkout-lock-shell)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gui-lock-checkout-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env["WR_GUI_LOCK_DIR"] = os.path.join(self.tmp, "locks")
        for name in ("WR_GUI_LOCK", "WR_CHECKOUT_LOCK_TIMEOUT", "WR_CHECKOUT_LOCK_HELD"):
            self.env.pop(name, None)
        self.checkout = os.path.join(self.tmp, "checkout")
        os.mkdir(self.checkout)

    def build(self, name, checkout=None, env=None, command=None):
        return Run(self, name, "checkout", env=env, command=command, label="make " + name,
                   options=["--checkout", checkout or self.checkout])

    def test_two_runs_in_one_checkout_take_turns(self):
        first = self.build("first")
        self.assertTrue(first.wait_started())
        second = self.build("second")
        self.assertTrue(second.stays_blocked(), "a second build started in the same DerivedData")
        self.assertEqual(first.finish_after_release(), 0)
        self.assertTrue(second.wait_started(), "the second build never got the checkout")
        second.release()
        code, _, err = second.finish()
        self.assertEqual(code, 0)
        self.assertIn("waiting for this checkout's macapp/DerivedData", err)
        self.assertIn("make first", err, "the waiting run must name the run in its way")

    def test_other_checkouts_build_at_once(self):
        other = os.path.join(self.tmp, "other")
        os.mkdir(other)
        first = self.build("first")
        second = self.build("second", checkout=other)
        self.assertTrue(first.wait_started())
        self.assertTrue(second.wait_started(), "two workrooms' builds must not exclude each other")
        self.assertEqual(first.finish_after_release(), 0)
        self.assertEqual(second.finish_after_release(), 0)

    def test_a_symlinked_path_is_the_same_checkout(self):
        alias = os.path.join(self.tmp, "alias")
        os.symlink(self.checkout, alias)
        first = self.build("first")
        self.assertTrue(first.wait_started())
        second = self.build("second", checkout=alias)
        self.assertTrue(second.stays_blocked())

    def test_a_make_started_under_the_lock_does_not_wait_for_it(self):
        # A locked recipe that runs `$(MAKE) app-test` must not deadlock on its own lock.
        started = os.path.join(self.tmp, "inner.started")
        release = os.path.join(self.tmp, "inner.release")
        inner = [sys.executable, HELPER, "checkout", "--checkout", self.checkout, "--",
                 sys.executable, "-c", BLOCKER, started, release, "0"]
        outer = self.build("outer", command=inner)
        deadline = time.time() + PROMPTLY
        while not os.path.exists(started) and time.time() < deadline:
            time.sleep(0.02)
        self.assertTrue(os.path.exists(started), "the nested run waited on its parent's lock")
        open(release, "w").close()
        self.assertEqual(outer.finish()[0], 0)

    def test_a_killed_holder_frees_the_checkout(self):
        first = self.build("first")
        self.assertTrue(first.wait_started())
        second = self.build("second")
        self.assertTrue(second.stays_blocked())
        first.process.kill()
        self.assertTrue(second.wait_started())

    def test_exit_status_is_the_commands(self):
        self.assertEqual(self.build("fails", command=[sys.executable, "-c", "exit(3)"])
                         .finish()[0], 3)

    def test_timeout_gives_up_with_ex_tempfail(self):
        first = self.build("first")
        self.assertTrue(first.wait_started())
        second = self.build("second", env={"WR_CHECKOUT_LOCK_TIMEOUT": "0.5"})
        code, _, err = second.finish()
        self.assertEqual(code, 75)
        self.assertFalse(second.has_started())
        self.assertIn("WR_CHECKOUT_LOCK_TIMEOUT", err)

    def test_gui_lock_off_does_not_bypass_it(self):
        # WR_GUI_LOCK=off is for the GUI session; DerivedData is shared however tests run.
        first = self.build("first")
        self.assertTrue(first.wait_started())
        second = self.build("second", env={"WR_GUI_LOCK": "off"})
        self.assertTrue(second.stays_blocked())

    def test_checkout_is_required(self):
        result = subprocess.run(
            [sys.executable, HELPER, "checkout", "--", "true"], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 2)


class CheckoutLockShellTests(unittest.TestCase):
    """make runs a locked target's recipe lines as `checkout-lock-shell -c LINE`."""

    SHELL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "checkout-lock-shell")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="gui-lock-shell-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.env = dict(os.environ)
        self.env["WR_GUI_LOCK_DIR"] = os.path.join(self.tmp, "locks")
        self.env.pop("WR_CHECKOUT_LOCK_HELD", None)

    def test_runs_the_line_in_the_callers_directory_with_its_status(self):
        result = subprocess.run(
            [self.SHELL, "-c", "pwd; echo \"$WR_CHECKOUT_LOCK_HELD\"; exit 4"], cwd=self.tmp,
            env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            universal_newlines=True)
        self.assertEqual(result.returncode, 4, result.stderr)
        cwd, held = result.stdout.splitlines()
        self.assertEqual(os.path.realpath(cwd), os.path.realpath(self.tmp))
        self.assertTrue(held.startswith("checkout-"), held)

    def test_make_runs_a_locked_target_through_it(self):
        makefile = os.path.join(self.tmp, "Makefile")
        with open(makefile, "w") as handle:
            handle.write("locked: SHELL := %s\nlocked:\n\t@echo \"$$WR_CHECKOUT_LOCK_HELD\"\n"
                         "plain:\n\t@echo \"[$$WR_CHECKOUT_LOCK_HELD]\"\n" % self.SHELL)
        result = subprocess.run(
            ["make", "-s", "-f", makefile, "locked", "plain"], cwd=self.tmp, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        locked, plain = result.stdout.splitlines()
        self.assertTrue(locked.startswith("checkout-"), locked)
        self.assertEqual(plain, "[]")


if __name__ == "__main__":
    unittest.main(verbosity=1)
