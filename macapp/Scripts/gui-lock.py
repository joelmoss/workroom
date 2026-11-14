#!/usr/bin/env python3
"""Share this Mac's one GUI session between app test runs from several checkouts.

    gui-lock.py shared    [--label TEXT] -- COMMAND [ARG...]   # hosted unit tests (make app-test)
    gui-lock.py exclusive [--label TEXT] -- COMMAND [ARG...]   # XCUITest (make app-uitest)
    gui-lock.py status                                         # who holds it; never waits
    gui-lock.py vm-slot   [--slots N] [--label TEXT] -- COMMAND [ARG...]  # a Tart guest (app-uitest-vm)
    gui-lock.py vm-status [--slots N]                          # who holds the VM slots; never waits
    gui-lock.py checkout  --checkout DIR [--label TEXT] -- COMMAND [ARG...]  # one build per checkout

Runs COMMAND while holding a machine-wide lock, then exits with COMMAND's status.

Why a lock at all. Every workroom builds its own "Workroom Dev" (see dev-identity.sh), so test runs
from different workrooms no longer share preferences, sockets or the app LaunchServices thinks is
running. They still share the screen. XCUITest drives the real pointer and keyboard and clicks at
screen coordinates, and a hosted unit run boots the whole app, whose real WindowGroup window renders
under XCTest (WorkroomApp.swift, the `.task` bootstrap guard). So one UI-test run needs the GUI
session to itself, while any number of unit runs can share it with each other:

  shared     many holders at once; waits while a UI-test run holds the session or is queued for it
  exclusive  one holder, and no shared holders

Queued exclusive runs go first. A shared run that arrives while a UI-test run is waiting queues
behind it, so a stream of unit runs from several workrooms cannot starve a UI-test run forever.

The lock is flock(2) on files under WR_GUI_LOCK_DIR (default ~/.cache/workroom/locks, beside the
ghostty-vt cache every checkout already shares). A kernel lock is released when its holder dies,
however it dies, so a crashed or killed run never leaves the session locked. The lock's file
descriptors are not inheritable, so nothing COMMAND starts (a session helper that outlives the
test, say) can keep holding it after this process exits. HOME rather than TMPDIR on purpose: an
agent's command sandbox can move TMPDIR, and two runs that disagree about the path would not
exclude each other at all.

Environment:
  WR_GUI_LOCK=off          run COMMAND without the lock (a VM run, or you know the screen is free)
  WR_GUI_LOCK_TIMEOUT=SECS give up after SECS of waiting, exit 75 (EX_TEMPFAIL); 0 = do not wait
  WR_GUI_LOCK_DIR=PATH     where the lock files live

Exit status: COMMAND's own; 128+N if COMMAND was killed by signal N, or this helper was while it
waited; 75 on timeout; 2 on a usage error. If the lock files cannot be created at all, COMMAND runs
without the lock and a warning says so: this coordinates runs, it is not a gate on them.

VM slots. `make app-uitest-vm` runs UI tests in Tart macOS guests instead of on this Mac's screen,
so they need no GUI session, but Virtualization.framework runs at most two macOS guests at once and
a third `tart run` fails. `vm-slot` is a counting lock for that: N slots (default 2), each a flock
on its own file `vm.slot-<i>` under WR_VM_LOCK_DIR (default ~/.cache/workroom/vm-locks). A run takes
the first free slot, waiting with the same "waiting for …" messages while all are taken, and runs
COMMAND with WR_VM_SLOT=<i> so it can name its guest after the slot. Unlike the GUI lock it fails
closed: if the lock files cannot be used it exits 75 with the reason rather than running unlocked,
because an uncounted third guest fails to boot and takes its run down with it; WR_GUI_LOCK=off does
not apply to it. WR_VM_LOCK_TIMEOUT works as WR_GUI_LOCK_TIMEOUT does. `vm-status` exits 1 while
every slot is held.

Checkout lock. The `make app-*` targets that build or test (see CHECKOUT_LOCKED_TARGETS in
mk/app.mk) share their checkout's macapp/DerivedData, and two at once in one checkout corrupt it: a
second xcodebuild fails codesign with "different Team IDs" or "bundle format unrecognized" and
reads as a code bug. `checkout` is an exclusive flock keyed by the checkout's real path, kept under
WR_GUI_LOCK_DIR (not in DerivedData, which `make app-clean` deletes). Other checkouts never wait on
it. COMMAND runs with WR_CHECKOUT_LOCK_HELD set to the key, so a `make` it starts in the same
checkout does not wait for its own parent. WR_CHECKOUT_LOCK_TIMEOUT works as WR_GUI_LOCK_TIMEOUT
does; WR_GUI_LOCK=off does not apply, since the build folder is shared however the tests run. If
the lock files cannot be created, COMMAND runs without it and a warning says so.

Standard library only, and Python 3.9 (Xcode's python3) compatible, so it runs anywhere xcodebuild
does.
"""

import errno
import fcntl
import hashlib
import os
import signal
import subprocess
import sys
import time

EX_TEMPFAIL = 75
POLL_SECONDS = 0.25
REMIND_SECONDS = 60.0


def log(message):
    sys.stderr.write("gui-lock: %s\n" % message)
    sys.stderr.flush()


def lock_dir():
    default = os.path.join(os.path.expanduser("~"), ".cache", "workroom", "locks")
    path = os.environ.get("WR_GUI_LOCK_DIR") or default
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def vm_lock_dir():
    default = os.path.join(os.path.expanduser("~"), ".cache", "workroom", "vm-locks")
    path = os.environ.get("WR_VM_LOCK_DIR") or default
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


GUI_HOLDERS = "gui.holders"
VM_HOLDERS = "vm.holders"


def holders_dir(root, name=GUI_HOLDERS):
    path = os.path.join(root, name)
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def open_lock_file(path):
    # Python opens these O_CLOEXEC (PEP 446), so no child ever inherits the lock.
    return os.open(path, os.O_RDWR | os.O_CREAT, 0o600)


def try_flock(fd, operation):
    try:
        fcntl.flock(fd, operation | fcntl.LOCK_NB)
        return True
    except OSError as error:
        if error.errno in (errno.EWOULDBLOCK, errno.EAGAIN, errno.EACCES):
            return False
        raise


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_holders(root, name=GUI_HOLDERS):
    """Live holder records, as (pid, mode, started, label). Records a killed holder left behind are
    pruned here; the lock itself never depended on them."""
    try:
        directory = holders_dir(root, name)
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    holders = []
    for name in names:
        if not name.isdigit():
            continue
        path = os.path.join(directory, name)
        try:
            with open(path) as record:
                mode, started, label = record.read().rstrip("\n").split("\t", 2)
        except (OSError, ValueError):
            continue
        pid = int(name)
        if not pid_alive(pid):
            try:
                os.unlink(path)
            except OSError:
                pass
            continue
        try:
            started = float(started)
        except ValueError:
            started = time.time()
        holders.append((pid, mode, started, label))
    return holders


def write_holder(root, mode, label, name=GUI_HOLDERS):
    """Record who holds (or is queued for) the session, for other runs' messages. Best effort: the
    lock is the flock, and a record that cannot be written must not fail the run."""
    try:
        path = os.path.join(holders_dir(root, name), str(os.getpid()))
        staged = path + ".tmp"
        with open(staged, "w") as record:
            record.write("%s\t%f\t%s\n" % (mode, time.time(), label.replace("\n", " ")))
        os.rename(staged, path)
        return path
    except OSError:
        return None


def duration(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)


def describe(holders):
    now = time.time()
    return [
        "  %-9s %s  (pid %d, %s)" % (mode, label, pid, duration(now - started))
        for pid, mode, started, label in holders
    ]


class Interrupted(Exception):
    def __init__(self, signum):
        Exception.__init__(self, signum)
        self.signum = signum


def raise_interrupted(signum, _frame):
    raise Interrupted(signum)


def wait_for(acquire, root, mode, deadline, waiting=None, holders_name=GUI_HOLDERS):
    """Poll `acquire` until it succeeds. Says who is in the way once (`waiting`, or the GUI
    session's reason), and again every REMIND_SECONDS, so a queued run explains itself instead of
    looking hung."""
    if acquire():
        return True
    started = time.time()
    reminded = 0.0
    while True:
        now = time.time()
        if now - reminded >= REMIND_SECONDS:
            holders = read_holders(root, holders_name)
            if reminded == 0.0:
                if waiting is None:
                    why = "UI tests need it to themselves" if mode == "exclusive" else (
                        "a UI-test run is using it or queued for it")
                    waiting = "waiting for this Mac's GUI session (%s)" % why
                log("%s. Held by:" % waiting)
            else:
                log("still waiting (%s). Held by:" % duration(now - started))
            for line in describe(holders) or ["  (a run that is about to start or finish)"]:
                sys.stderr.write(line + "\n")
            sys.stderr.flush()
            reminded = now
        if deadline is not None and now >= deadline:
            return False
        time.sleep(POLL_SECONDS)
        if acquire():
            log("acquired (%s) after %s" % (mode, duration(time.time() - started)))
            return True


def run_unlocked(command):
    try:
        os.execvp(command[0], command)
    except OSError as error:
        log("cannot run %s: %s" % (command[0], error.strerror))
        return 127 if error.errno == errno.ENOENT else 126


def run_holding(command, env=None):
    """Run COMMAND to its end while the caller holds its lock, and return its exit status.

    The command owns the terminal. Ctrl-C reaches it directly (it shares our process group), so
    this process just waits for it to exit rather than dropping the lock under a run that is still
    cleaning up; a signal sent to this process alone is passed on. Python-level handlers, never
    SIG_IGN: exec resets a caught signal to its default in the child, but an ignored one would stay
    ignored, and xcodebuild would then shrug off Ctrl-C."""
    child = []

    def forward(signum, _frame):
        if child and child[0].poll() is None:
            child[0].send_signal(signum)

    signal.signal(signal.SIGINT, lambda _signum, _frame: None)
    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGHUP, forward)
    try:
        child.append(subprocess.Popen(command, env=env))
    except OSError as error:
        log("cannot run %s: %s" % (command[0], error.strerror))
        return 127 if error.errno == errno.ENOENT else 126
    status = child[0].wait()
    return 128 - status if status < 0 else status


def deadline_from(variable):
    timeout = os.environ.get(variable, "").strip()
    if not timeout:
        return None, timeout
    try:
        return time.time() + max(0.0, float(timeout)), timeout
    except ValueError:
        log("ignoring %s=%r (not a number of seconds)" % (variable, timeout))
        return None, timeout


def run_locked(mode, label, command):
    try:
        root = lock_dir()
        turnstile = open_lock_file(os.path.join(root, "gui.turnstile"))
        session = open_lock_file(os.path.join(root, "gui.lock"))
    except OSError as error:
        # Still runs — a coordination aid must not turn an unwritable HOME into a failed test run
        # (`test_an_unusable_lock_directory_runs_the_command_unlocked`). But say what is lost, not
        # just that something was: unlocked, an exclusive run no longer has the session to itself,
        # and two workrooms' UI tests driving one GUI read as unattributable test flake rather than
        # as the broken lock directory they are.
        log(
            "cannot use the lock (%s); running without it — nothing is coordinating the GUI "
            "session now, so another workroom's run can overlap this %s" % (error, label)
        )
        return run_unlocked(command)
    deadline, timeout = deadline_from("WR_GUI_LOCK_TIMEOUT")

    # Two locks give queued UI-test runs priority. `gui.turnstile` is the queue: an exclusive run
    # holds it from the moment it starts waiting until it finishes, and a shared run only passes
    # through it on the way in, so no shared run can start while an exclusive one is queued or
    # running. `gui.lock` is the session itself.
    record = None
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, raise_interrupted)
    try:
        try:
            acquired = wait_for(
                lambda: try_flock(turnstile, fcntl.LOCK_EX), root, mode, deadline)
            if acquired and mode == "exclusive":
                # Visible to the runs queued behind it, which would otherwise see only the shared
                # holders it is waiting out and not know why they are waiting too.
                record = write_holder(root, "queued", label)
                acquired = wait_for(
                    lambda: try_flock(session, fcntl.LOCK_EX), root, mode, deadline)
            elif acquired:
                acquired = wait_for(
                    lambda: try_flock(session, fcntl.LOCK_SH), root, mode, deadline)
                fcntl.flock(turnstile, fcntl.LOCK_UN)
            if not acquired:
                log("gave up after WR_GUI_LOCK_TIMEOUT=%s seconds" % timeout)
                return EX_TEMPFAIL
            record = write_holder(root, mode, label) or record
        except Interrupted as interrupted:
            return 128 + interrupted.signum
        return run_holding(command)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        if record is not None:
            try:
                os.unlink(record)
            except OSError:
                pass
        os.close(session)
        os.close(turnstile)


DEFAULT_VM_SLOTS = 2


def open_vm_slots(slots):
    """The lock directory and one open lock file per slot. Raises OSError when they cannot be
    used, holders directory included, so a run never starts on a lock that half works."""
    root = vm_lock_dir()
    holders_dir(root, VM_HOLDERS)
    files = []
    try:
        for index in range(1, slots + 1):
            files.append(open_lock_file(os.path.join(root, "vm.slot-%d" % index)))
    except OSError:
        for fd in files:
            os.close(fd)
        raise
    return root, files


def run_in_vm_slot(slots, label, command):
    """Run COMMAND holding one of `slots` VM slots, with WR_VM_SLOT set to its number. Fails
    closed: exit 75 if the lock cannot be used, never run unlocked."""
    try:
        root, files = open_vm_slots(slots)
    except OSError as error:
        log("cannot use the VM slot lock (%s); not starting a guest without it, since this Mac runs "
            "at most %d and an uncounted one fails to boot. Fix the directory or point "
            "WR_VM_LOCK_DIR elsewhere" % (error, slots))
        return EX_TEMPFAIL
    deadline, timeout = deadline_from("WR_VM_LOCK_TIMEOUT")
    held = []

    def acquire():
        for index, fd in enumerate(files, 1):
            if try_flock(fd, fcntl.LOCK_EX):
                held.append(index)
                return True
        return False

    record = None
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, raise_interrupted)
    try:
        try:
            waiting = "waiting for a VM slot (this Mac runs %d guest%s at once)" % (
                slots, "" if slots == 1 else "s")
            if not wait_for(acquire, root, "vm-slot", deadline, waiting, VM_HOLDERS):
                log("gave up after WR_VM_LOCK_TIMEOUT=%s seconds" % timeout)
                return EX_TEMPFAIL
            record = write_holder(root, "slot %d" % held[0], label, VM_HOLDERS)
        except Interrupted as interrupted:
            return 128 + interrupted.signum
        except OSError as error:
            log("cannot use the VM slot lock (%s); not starting a guest without it" % error)
            return EX_TEMPFAIL
        env = dict(os.environ)
        env["WR_VM_SLOT"] = str(held[0])
        return run_holding(command, env)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        if record is not None:
            try:
                os.unlink(record)
            except OSError:
                pass
        for fd in files:
            os.close(fd)


def vm_status(slots):
    """Print the VM slot holders. Exit 1 while every slot is held (a new run would wait), else 0.
    Counts by the flocks themselves, so a record a run had no time to write still counts."""
    try:
        root, files = open_vm_slots(slots)
    except OSError as error:
        print("gui-lock: VM slot lock unusable (%s), so no guest run can start" % error)
        return 1
    busy = 0
    for fd in files:
        if try_flock(fd, fcntl.LOCK_EX):
            fcntl.flock(fd, fcntl.LOCK_UN)
        else:
            busy += 1
        os.close(fd)
    holders = read_holders(root, VM_HOLDERS)
    print("gui-lock: %d of %d VM slot%s in use" % (busy, slots, "" if slots == 1 else "s"))
    for line in describe(holders):
        print(line)
    return 1 if busy >= slots else 0


CHECKOUT_HELD = "WR_CHECKOUT_LOCK_HELD"


def checkout_key(checkout):
    real = os.path.realpath(checkout)
    return "checkout-" + hashlib.sha1(real.encode("utf-8", "surrogateescape")).hexdigest()[:12]


def run_checkout_locked(checkout, label, command):
    """Run COMMAND holding CHECKOUT's build lock, waiting for another run in that checkout."""
    key = checkout_key(checkout)
    if os.environ.get(CHECKOUT_HELD) == key:
        # A make started by a run that already holds this checkout's lock.
        return run_unlocked(command)
    try:
        root = lock_dir()
        lock = open_lock_file(os.path.join(root, key + ".lock"))
    except OSError as error:
        log("cannot use the checkout lock (%s); running without it, so another make app-* in "
            "%s can share its DerivedData" % (error, checkout))
        return run_unlocked(command)
    deadline, timeout = deadline_from("WR_CHECKOUT_LOCK_TIMEOUT")
    holders = key + ".holders"
    record = None
    previous = {}
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[signum] = signal.signal(signum, raise_interrupted)
    try:
        try:
            waiting = ("waiting for this checkout's macapp/DerivedData (one make app-* build or "
                       "test at a time in %s)" % checkout)
            if not wait_for(lambda: try_flock(lock, fcntl.LOCK_EX), root, "checkout", deadline,
                            waiting, holders):
                log("gave up after WR_CHECKOUT_LOCK_TIMEOUT=%s seconds" % timeout)
                return EX_TEMPFAIL
            record = write_holder(root, "build", label, holders)
        except Interrupted as interrupted:
            return 128 + interrupted.signum
        env = dict(os.environ)
        env[CHECKOUT_HELD] = key
        return run_holding(command, env)
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        if record is not None:
            try:
                os.unlink(record)
            except OSError:
                pass
        os.close(lock)


def status():
    """Print the current holders. Exit 1 while a UI-test run holds the session, else 0."""
    try:
        holders = read_holders(lock_dir())
    except OSError as error:
        print("gui-lock: no lock directory (%s), so nothing can hold it" % error)
        return 0
    if not holders:
        print("gui-lock: free")
        return 0
    print("gui-lock: held by")
    for line in describe(holders):
        print(line)
    return 1 if any(mode == "exclusive" for _, mode, _, _ in holders) else 0


def usage(message=None):
    if message:
        log(message)
    sys.stderr.write(
        "usage: gui-lock.py shared|exclusive [--label TEXT] -- COMMAND [ARG...]\n"
        "       gui-lock.py status\n"
        "       gui-lock.py vm-slot [--slots N] [--label TEXT] -- COMMAND [ARG...]\n"
        "       gui-lock.py vm-status [--slots N]\n"
        "       gui-lock.py checkout --checkout DIR [--label TEXT] -- COMMAND [ARG...]\n")
    return 2


def parse_slots(rest):
    """Strip a leading `--slots N`. Returns (slots, rest), or (None, message) on a bad value."""
    if rest[:1] != ["--slots"]:
        return DEFAULT_VM_SLOTS, rest
    if len(rest) < 2 or not rest[1].isdigit() or int(rest[1]) < 1:
        return None, "--slots needs a whole number of at least 1"
    return int(rest[1]), rest[2:]


def main(argv):
    if not argv:
        return usage()
    mode = argv[0]
    if mode == "status" and len(argv) == 1:
        return status()
    if mode not in ("shared", "exclusive", "vm-slot", "vm-status", "checkout"):
        return usage("unknown mode %r" % mode)
    rest = argv[1:]
    checkout = None
    if mode == "checkout":
        if rest[:1] != ["--checkout"] or len(rest) < 2:
            return usage("checkout needs --checkout DIR")
        checkout, rest = rest[1], rest[2:]
    slots = DEFAULT_VM_SLOTS
    if mode in ("vm-slot", "vm-status"):
        slots, rest = parse_slots(rest)
        if slots is None:
            return usage(rest)
        if mode == "vm-status":
            return vm_status(slots) if not rest else usage("vm-status takes only --slots")
    label = os.getcwd()
    if rest[:1] == ["--label"]:
        if len(rest) < 2:
            return usage("--label needs a value")
        label, rest = rest[1], rest[2:]
    if rest[:1] != ["--"] or len(rest) < 2:
        return usage("expected -- COMMAND")
    command = rest[1:]
    if mode == "checkout":
        return run_checkout_locked(checkout, label, command)
    if mode == "vm-slot":
        # Before the WR_GUI_LOCK=off check on purpose: that switch is for the GUI session, which a
        # guest does not use, and the guest count is a limit this Mac enforces whatever it says.
        return run_in_vm_slot(slots, label, command)
    if os.environ.get("WR_GUI_LOCK", "").strip().lower() in ("off", "0", "no", "false"):
        return run_unlocked(command)
    return run_locked(mode, label, command)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
