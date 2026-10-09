//! A session's shell must not inherit the crash handler of whatever started the agent (#329).
//!
//! The app's crash reporter holds a Mach exception port for EXC_BAD_ACCESS. Every process the app
//! starts inherits it, and the handler never answers for them, so a program that segfaults inside
//! a Workroom terminal hangs instead of getting its SIGSEGV. This test stands in for the app with a
//! live port of its own, starts the agent under it, and has the session's shell run a probe.
#![cfg(target_os = "macos")]

use std::io::Write;
use std::time::Duration;

#[allow(dead_code)] // not every helper is used here
mod common;
use common::*;

const SESSION: &str = "32900000-0000-4000-8000-000000000329";
/// Set only for the copy of this binary the session's shell runs.
const PROBE: &str = "WR_AGENT_EXCEPTION_PORT_PROBE";

const EXC_MASK_BAD_ACCESS: libc::c_uint = 1 << 1;
const EXC_TYPES_COUNT: usize = 14;
const EXCEPTION_DEFAULT: libc::c_int = 1;
const MACH_EXCEPTION_CODES: libc::c_int = 0x8000_0000_u32 as libc::c_int;
#[cfg(target_arch = "aarch64")]
const THREAD_STATE_NONE: libc::c_int = 5;
#[cfg(target_arch = "x86_64")]
const THREAD_STATE_NONE: libc::c_int = 13;
const MACH_PORT_RIGHT_RECEIVE: libc::c_uint = 1;
const MACH_MSG_TYPE_MAKE_SEND: libc::c_uint = 20;

extern "C" {
    // What <mach/mach_init.h>'s `mach_task_self()` reads.
    static mach_task_self_: libc::mach_port_t;
    fn mach_port_allocate(
        task: libc::mach_port_t,
        right: libc::c_uint,
        name: *mut libc::mach_port_t,
    ) -> libc::c_int;
    fn mach_port_insert_right(
        task: libc::mach_port_t,
        name: libc::mach_port_t,
        right: libc::mach_port_t,
        right_type: libc::c_uint,
    ) -> libc::c_int;
    fn task_set_exception_ports(
        task: libc::mach_port_t,
        exception_mask: libc::c_uint,
        new_port: libc::mach_port_t,
        behavior: libc::c_int,
        new_flavor: libc::c_int,
    ) -> libc::c_int;
    fn task_get_exception_ports(
        task: libc::mach_port_t,
        exception_mask: libc::c_uint,
        masks: *mut libc::c_uint,
        count: *mut libc::c_uint,
        ports: *mut libc::mach_port_t,
        behaviors: *mut libc::c_int,
        flavors: *mut libc::c_int,
    ) -> libc::c_int;
}

/// This task's EXC_BAD_ACCESS port, 0 when there is none: the probe from #329.
fn bad_access_port() -> libc::mach_port_t {
    let mut masks = [0; EXC_TYPES_COUNT];
    let mut count = EXC_TYPES_COUNT as libc::c_uint;
    let mut ports = [0; EXC_TYPES_COUNT];
    let mut behaviors = [0; EXC_TYPES_COUNT];
    let mut flavors = [0; EXC_TYPES_COUNT];
    let kr = unsafe {
        task_get_exception_ports(
            mach_task_self_,
            EXC_MASK_BAD_ACCESS,
            masks.as_mut_ptr(),
            &mut count,
            ports.as_mut_ptr(),
            behaviors.as_mut_ptr(),
            flavors.as_mut_ptr(),
        )
    };
    assert_eq!(kr, 0, "task_get_exception_ports");
    ports[..count as usize]
        .iter()
        .copied()
        .find(|&p| p != 0)
        .unwrap_or(0)
}

/// What Sentry does in the app: a port this process receives on, for EXC_BAD_ACCESS, with the
/// same behaviour the issue's probe reported (`0x80000001`). Never deallocated, so it stays live
/// for the whole test, as the app's does while the app runs.
fn install_live_port() -> libc::mach_port_t {
    let task = unsafe { mach_task_self_ };
    let mut port = 0;
    unsafe {
        assert_eq!(
            mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &mut port),
            0
        );
        assert_eq!(
            mach_port_insert_right(task, port, port, MACH_MSG_TYPE_MAKE_SEND),
            0
        );
        assert_eq!(
            task_set_exception_ports(
                task,
                EXC_MASK_BAD_ACCESS,
                port,
                EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES,
                THREAD_STATE_NONE,
            ),
            0
        );
    }
    port
}

/// Not a check of its own: the session's shell runs this binary with `PROBE` set, and this prints
/// what that process inherited.
#[test]
fn probe() {
    if std::env::var_os(PROBE).is_some() {
        println!("exception-port=0x{:x};", bad_access_port());
    }
}

#[test]
fn a_session_shell_does_not_inherit_the_exception_port_the_agent_started_with() {
    let port = install_live_port();
    // Guards the test itself: without a live port here, `0x0` below would prove nothing.
    assert_eq!(
        bad_access_port(),
        port,
        "the stand-in port was not installed"
    );

    let workspace = Workspace::new("exception-ports");
    let socket = workspace.socket();
    let _agent = start_agent(&socket);

    let mut client = attach(&socket, SESSION);
    let probe = std::env::current_exe().expect("test binary");
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        // Lets the shell print its prompt first, so the command is not swallowed.
        std::thread::sleep(Duration::from_millis(400));
        writeln!(
            stdin,
            "{PROBE}=1 '{}' --exact probe --nocapture --test-threads=1",
            probe.display()
        )
        .expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("test result", Duration::from_secs(20));
    let reported = seen
        .split("exception-port=")
        .nth(1)
        .and_then(|rest| rest.split(';').next());
    assert_eq!(
        reported,
        Some("0x0"),
        "a program in the session inherited an exception port; got {seen:?}"
    );
}
