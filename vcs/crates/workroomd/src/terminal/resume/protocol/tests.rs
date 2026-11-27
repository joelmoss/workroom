//! Ported from herdr-core's `resume/protocol.rs` tests (see the parent module's header), Licensed
//! under the Apache License, Version 2.0. Changed for Workroom: an ignored report is an `Err` with
//! its reason, the scanner is fed its stream offset, and the Windows-only `cwd` case is dropped. The published reports are the spec's
//! own examples (https://www.superlogical.com/rex/docs/build/program-resume).

use super::*;

const TOKEN: &str = "dummy-token-replace-me";
const TIME: u64 = 1795543200;
const CLEAR: &[u8] = b"pid=74877:time=1795543200:clear=1:mac=c30603369f98fef581a4098be889175b0c74f0641e49f8b25f4326cb38f97c93";

#[test]
fn authenticates_the_published_reports() {
    for (body, expected) in [
        (
            "pid=74877:time=1795543200:argv=bnZpbQ==,LVM=,L2hvbWUvdXNlci8ubG9jYWwvc3RhdGUvbnZpbS9zZXNzaW9ucy84ZjJjMWQudmlt:mac=9dbb99bfb856749a87563839d7ce9062818d78cf25909db93f309e0cd3b1909b",
            "nvim",
        ),
        (
            "pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1",
            "lazygit",
        ),
        (
            "pid=90412:time=1795543200:argv=cmVzdW1lLXdyYXA=,c3No,ZGV2Ym94:mac=e76149d0ba54a83570ffab0583867dacdfa23928ba9d18604f0badea88b62b65",
            "resume-wrap",
        ),
    ] {
        let report = authenticate(body.as_bytes(), TOKEN, TIME).unwrap();
        let Some(Action::Set { argv, .. }) = report.action else {
            panic!("set report")
        };
        assert_eq!(argv[0], expected);
    }
    assert_eq!(
        authenticate(CLEAR, TOKEN, TIME).unwrap().action,
        Some(Action::Clear)
    );
    assert!(authenticate(CLEAR, TOKEN, TIME - 60).is_ok());
    assert!(authenticate(CLEAR, TOKEN, TIME + 60).is_ok());
    assert_eq!(
        authenticate(CLEAR, TOKEN, TIME - 61),
        Err(Reason::StaleTime)
    );
    assert_eq!(
        authenticate(CLEAR, TOKEN, TIME + 61),
        Err(Reason::StaleTime)
    );
    assert_eq!(
        authenticate(CLEAR, "other-token", TIME),
        Err(Reason::BadMac)
    );
}

#[test]
fn the_lazygit_report_carries_its_folder() {
    let body = b"pid=74877:time=1795543200:argv=bGF6eWdpdA==:cwd=L2hvbWUvdXNlci9zcmMvcHJvamVjdA==:mac=35cb909805c380336efd3689a125acc774a9dec8422a1d21492ebec06ca758e1";
    assert_eq!(
        authenticate(body, TOKEN, TIME).unwrap(),
        Report {
            pid: 74877,
            time: TIME,
            action: Some(Action::Set {
                argv: vec!["lazygit".into()],
                cwd: Some("/home/user/src/project".into()),
            }),
        }
    );
}

#[test]
fn frames_at_every_split_and_restarts_after_an_unterminated_string() {
    for end in [b"\x07".as_slice(), b"\x1b\\"] {
        let frame = [OPEN, CLEAR, end].concat();
        for split in 0..=frame.len() {
            let (mut stream, mut offset) = (Stream::default(), 0);
            let mut reports = stream.feed(&mut offset, &frame[..split]);
            reports.extend(stream.feed(&mut offset, &frame[split..]));
            assert_eq!(reports, [(frame.len() as u64, CLEAR.to_vec())]);
        }
        let (mut stream, mut offset) = (Stream::default(), 0);
        let interrupted = [b"output\x1b]0;".as_slice(), &frame].concat();
        assert_eq!(
            stream.feed(&mut offset, &interrupted),
            [(interrupted.len() as u64, CLEAR.to_vec())]
        );
        assert!(
            stream
                .feed(&mut offset, &[OPEN, CLEAR, b"\x18"].concat())
                .is_empty()
        );
        assert_eq!(stream.feed(&mut offset, &frame).len(), 1);

        let size = LIMIT - OPEN.len() - end.len();
        assert_eq!(
            stream
                .feed(&mut offset, &[OPEN, &vec![b'a'; size], end].concat())
                .len(),
            1
        );
        assert!(
            stream
                .feed(&mut offset, &[OPEN, &vec![b'a'; size + 1], end].concat())
                .is_empty()
        );
    }
}

#[test]
fn authenticated_malformed_reports_reject_but_untrusted_ones_are_ignored() {
    let parse = |fields| {
        let body = format!("pid=5:time={TIME}:{fields}");
        let body = format!("{body}:mac={}", mac(body.as_bytes(), TOKEN));
        authenticate(body.as_bytes(), TOKEN, TIME)
    };
    for bad in [
        "argv=Yg==:argv=Yg==",
        "argv=Yg==:clear=1",
        "argv=Yg==:need=later",
        "argv=Yg==:Tag=x",
        "argv=Yg==:unknown=!",
        "argv=Yg==:need=",
        "argv=Yg=",
        "argv=Yh==",
        "argv=Yg===",
        "argv=Yg==,wqA=,AA==",
        "argv=Yg==,f4A=",
        "argv=Yg==,woA=",
        "argv=",
        "argv=Li9h",
        "argv=LWE=",
        "argv=Yg==:cwd=cmVs",
        "clear=0",
        "clear=1:pid=5",
    ] {
        assert_eq!(parse(bad).unwrap().action, None, "{bad}");
    }
    assert_eq!(
        parse("argv=Yg,LA==,:unused=abc").unwrap().action,
        Some(Action::Set {
            argv: vec!["b".into(), ",".into(), "".into()],
            cwd: None
        })
    );
    assert_eq!(parse("clear=1:pid=6"), Err(Reason::NoPid));
    assert_eq!(
        parse("clear=1:time=99999999999999999999999"),
        Err(Reason::StaleTime)
    );
    let args = format!("argv=Yg{}", ",YQ".repeat(63));
    assert!(parse(&args).unwrap().action.is_some());
    assert_eq!(parse(&format!("{args},YQ")).unwrap().action, None);
}
