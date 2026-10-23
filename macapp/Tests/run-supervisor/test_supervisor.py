#!/usr/bin/env python3
"""Integration test for the run-command supervisor (run_supervisor.sh) — issues #7, #522.

Runs the REAL run_supervisor.sh under a pseudo-tty (the same shape a daemon session gives it),
wrapping a fake rails-like server (fakeserver.py: binds a port, writes a pidfile, refuses to start
if the pidfile holds a LIVE pid, ignores SIGHUP like Puma). Exercises the full lifecycle and the
teardown/close paths, asserting NO orphaned server and NO "A server is already running" — the
process-level behaviour the mocked Swift unit tests can't see.

The control signals the daemon sends it: USR1=restart, USR2=stop(keep pane), TERM=quit. Killing
its session hangs up the PTY -> SIGHUP to the foreground group; we simulate that by closing the
master fd. Puma ignores SIGHUP, so only the supervisor catching SIGHUP and
stopping the child keeps it from orphaning.

Run: python3 test_supervisor.py   (exit 0 = all pass)
"""
import os
import sys
import pty
import time
import errno
import signal
import socket
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# The supervisor is embedded in workroomd (`workroomd run-supervisor`), which runs this script.
SUPERVISOR = os.path.normpath(
    os.path.join(HERE, "..", "..", "..", "vcs", "crates", "workroomd", "src", "run_supervisor.sh"))
FAKESERVER = os.path.join(HERE, "fakeserver.py")
PORT = 3111

fails = []


def check(cond, msg):
    print(("  ok  " if cond else "  FAIL ") + msg)
    if not cond:
        fails.append(msg)


def port_open(port=PORT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.2)
    try:
        s.connect(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_until(fn, secs=6.0):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if fn():
            return True
        time.sleep(0.05)
    return fn()


class Sup:
    """One supervisor instance over its own pty, sharing the given status/pidfile paths."""

    def __init__(self, status, pidfile, drain="0.3"):
        env = dict(os.environ, FAKE_PIDFILE=pidfile, FAKE_PORT=str(PORT), FAKE_DRAIN=drain)
        self.status, self.pidfile = status, pidfile
        pid, fd = pty.fork()
        if pid == 0:
            os.environ.update(env)
            os.execv("/bin/sh", ["/bin/sh", SUPERVISOR, status, "python3", "-u", FAKESERVER])
            os._exit(127)
        self.pid, self.fd = pid, fd
        os.set_blocking(fd, False)
        self.buf = ""

    def pump(self, secs=0.3):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            try:
                c = os.read(self.fd, 4096)
                if c:
                    self.buf += c.decode(errors="replace")
                else:
                    break
            except OSError as e:
                if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    time.sleep(0.02)
                else:
                    break

    def saw(self, needle, secs=5.0):
        end = time.monotonic() + secs
        while time.monotonic() < end:
            self.pump(0.1)
            if needle in self.buf:
                return True
        return needle in self.buf

    def server_pid(self):
        try:
            return int(open(self.pidfile).read().strip())
        except (FileNotFoundError, ValueError):
            return None

    def signal(self, sig):
        # The supervisor is the pty's child, as in a run session, which the daemon signals.
        os.kill(self.pid, sig)

    def hangup(self):
        """Simulate the app freeing the surface: close the pty master -> PTY hangup -> SIGHUP."""
        try:
            os.close(self.fd)
        except OSError:
            pass
        self.fd = None

    def reap(self):
        try:
            if self.fd is not None:
                os.close(self.fd)
        except OSError:
            pass
        self.fd = None
        # Kill the WHOLE process group, not just the supervisor: the server runs as a child in the
        # supervisor's group (pty.fork setsid'd it, so pgid == self.pid). Killing only self.pid would
        # leave the server lingering on the port and break the next test (the port-not-free flake).
        for sig in (signal.SIGKILL,):
            try:
                os.killpg(self.pid, sig)
            except OSError:
                pass
        try:
            os.kill(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        # Don't return until the port is actually released, so the next test's bind can't race a
        # still-closing socket from this instance.
        wait_until(lambda: not port_open(), 3.0)


def fresh_paths():
    d = tempfile.mkdtemp(prefix="suptest-")
    return os.path.join(d, "status"), os.path.join(d, "server.pid")


def free_port():
    # nothing should be on PORT between tests; assert it's clear
    return wait_until(lambda: not port_open(), 3.0)


print("=== supervisor integration test (port %d) ===" % PORT)
status, pidf = fresh_paths()

print("Test 1: run -> server up")
s = Sup(status, pidf)
check(s.saw("FAKE up", 6), "server started")
check(wait_until(port_open), "port is listening")
sp1 = s.server_pid()
check(sp1 is not None and pid_alive(sp1), "pidfile holds a live server pid (%s)" % sp1)

print("Test 2: stop (USR2) -> server dies, port frees, supervisor parks")
s.signal(signal.SIGUSR2)
check(wait_until(lambda: not pid_alive(sp1)), "server process exited")
check(wait_until(lambda: not port_open()), "port freed")
check(s.server_pid() is None, "pidfile removed")
check(pid_alive(s.pid), "supervisor still alive (parked)")

print("Test 3: restart-from-parked (USR1) -> fresh server, no 'already running'")
s.buf = ""
s.signal(signal.SIGUSR1)
check(s.saw("FAKE up", 6), "a fresh server started")
check("already running" not in s.buf, "no 'already running' on restart")
check(wait_until(port_open), "port listening again")
sp2 = s.server_pid()
check(sp2 and sp2 != sp1 and pid_alive(sp2), "new server pid (%s != %s)" % (sp2, sp1))

print("Test 4: CLOSE while RUNNING via SIGHUP (surface freed) -> NO orphan")
# The crux: Puma ignores SIGHUP; only the supervisor's SIGHUP trap stops the child. If the
# supervisor doesn't handle SIGHUP, sp2 orphans on the port -> the bug.
s.hangup()
check(wait_until(lambda: not pid_alive(sp2), 8), "server NOT orphaned after surface free (pid %s)" % sp2)
check(wait_until(lambda: not port_open(), 8), "port freed after close")
s.reap()

print("Test 5: stop -> close(SIGHUP) -> re-run (new supervisor) -> no 'already running'")
check(free_port(), "precondition: port free")
status, pidf = fresh_paths()
a = Sup(status, pidf)
check(a.saw("FAKE up", 6), "server A up")
spa = a.server_pid()
a.signal(signal.SIGUSR2)  # stop
check(wait_until(lambda: not pid_alive(spa)), "server A stopped")
a.hangup()  # close the terminal (surface freed) while parked
time.sleep(0.5)
check(not pid_alive(spa), "server A not resurrected/orphaned by close")
# the app would respawn a NEW surface for the next run:
b = Sup(status, pidf)
check(b.saw("FAKE up", 6), "server B started on re-run")
check("already running" not in b.buf, "NO 'A server is already running' on re-run after close")
check(wait_until(port_open), "port listening (server B)")
a.reap()
b.reap()

print("Test 6: CLOSE while RUNNING via SIGTERM (graceful app teardown) -> server dies")
check(free_port(), "precondition: port free")
status, pidf = fresh_paths()
c = Sup(status, pidf)
check(c.saw("FAKE up", 6), "server C up")
spc = c.server_pid()
c.signal(signal.SIGTERM)  # quit
check(wait_until(lambda: not pid_alive(spc)), "server C exited on SIGTERM")
check(wait_until(lambda: not port_open()), "port freed")
c.reap()

print("\n=== RESULT: " + ("ALL PASS" if not fails else "%d FAIL: %s" % (len(fails), fails)) + " ===")
sys.exit(1 if fails else 0)
