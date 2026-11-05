use super::*;

const BUSY: &[u8] = b"\x1b]9;4;3\x1b\\";
const IDLE: &[u8] = b"\x1b]9;4;0\x1b\\";

fn has(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// The row after an image 2 cells tall at 10x20 pixels a cell.
fn row_below_image(shadow: &mut Shadow) -> Option<usize> {
    let mut image = b"\x1b_Ga=T,f=24,s=40,v=40,i=7,q=2;".to_vec();
    image.extend_from_slice(&[b'A'; 6400]);
    image.extend_from_slice(b"\x1b\\");
    shadow.write(&image);
    shadow.write(b"\r\nBELOW");
    let text = shadow.terminal.as_ref()?.visible_text();
    text.lines().position(|line| line.contains("BELOW"))
}

/// Value: protects=text below an image stays on its rows after a reattach (#551);
/// fails_when=the shadow's cell size stays zero; why_new=no test placed an image; seam=none;
/// no_claim=the app's own cell size, which the attach tests carry here
#[test]
fn an_image_takes_its_rows_once_the_pixel_size_is_known() {
    let mut unsized_shadow = Shadow::new(80, 24);
    assert_eq!(row_below_image(&mut unsized_shadow), Some(1), "fixture");

    let mut shadow = Shadow::new(80, 24);
    shadow.resize(Size {
        columns: 80,
        rows: 24,
        x_pixels: 800,
        y_pixels: 480,
    });
    assert_eq!(row_below_image(&mut shadow), Some(2));
}

fn busy_from(owner: Option<libc::pid_t>) -> Shadow {
    let mut shadow = Shadow::new(80, 24);
    shadow.write_from_pty(b"working\r\n", || unreachable!("no report, so no question"));
    shadow.write_from_pty(BUSY, || owner);
    shadow
}

/// The report follows its sender: busy while it owns the pty, idle while another group does,
/// busy again when it is back (^Z then `fg`), and kept when nobody can say (#359).
/// Value: protects=replay_for says busy only while the sender owns the pty, without losing the report; fails_when=the owner comparison inverts, drops the report, or the owner is never noted; why_new=the session test needs job control and timing, this needs neither; seam=none
#[test]
fn the_progress_report_follows_the_program_that_sent_it() {
    let shadow = busy_from(Some(10));
    assert!(
        has(&shadow.replay_for(Some(10)), BUSY),
        "the sender owns the pty"
    );
    let elsewhere = shadow.replay_for(Some(20));
    assert!(
        !has(&elsewhere, BUSY) && has(&elsewhere, IDLE),
        "the sender has gone"
    );
    assert!(
        has(&shadow.replay_for(Some(10)), BUSY),
        "the sender came back"
    );
    assert!(
        has(&shadow.replay_for(None), BUSY),
        "unknown foreground keeps the report"
    );
    assert!(
        has(&busy_from(None).replay_for(Some(20)), BUSY),
        "unknown owner keeps the report"
    );
}

/// Each report belongs to whoever sent it: a program that reports busy after another one left
/// without clearing its report owns the new one.
/// Value: protects=a new report replaces the old sender; fails_when=the owner is noted only once, on the first report; why_new=the other test sends one report; seam=none
#[test]
fn a_new_report_belongs_to_its_own_sender() {
    let mut shadow = busy_from(Some(10));
    shadow.write_from_pty(BUSY, || Some(20));
    assert!(
        has(&shadow.replay_for(Some(20)), BUSY),
        "the new sender owns the pty"
    );
    assert!(
        !has(&shadow.replay_for(Some(10)), BUSY),
        "the old sender no longer counts"
    );
}

/// The shell's command end (OSC 133 D) clears the report it follows, even while the sender
/// still owns the pty; a report after it is the next command's (#464). A prompt start alone
/// clears nothing, as in the app.
/// Value: protects=a reattach after a command ended is told idle even when the reporter never sent REMOVE and still owns the pty, and a report after D is kept; fails_when=the D arm is removed, the clear runs after the whole read instead of at the D, or a prompt start clears too; why_new=no test fed OSC 133 D to the shadow; seam=none
#[test]
fn a_command_end_clears_only_the_report_before_it() {
    const D: &[u8] = b"\x1b]133;D;0\x07";
    let cases: [(&str, Vec<Vec<u8>>, bool); 6] = [
        (
            "D with an exit code clears",
            vec![BUSY.into(), D.into()],
            false,
        ),
        (
            "a bare D clears",
            vec![BUSY.into(), b"\x1b]133;D\x07".into()],
            false,
        ),
        (
            "D in the report's own read clears",
            vec![[BUSY, D].concat()],
            false,
        ),
        // Each after a held report, so the D has one to clear.
        (
            "a report after D in one read is kept",
            vec![BUSY.into(), [D, BUSY].concat()],
            true,
        ),
        (
            "a report after D is kept",
            vec![BUSY.into(), D.into(), BUSY.into()],
            true,
        ),
        (
            "a prompt start (A) keeps it",
            vec![BUSY.into(), b"\x1b]133;A\x07".into()],
            true,
        ),
    ];
    for (case, reads, busy) in cases {
        let mut shadow = Shadow::new(80, 24);
        shadow.write_from_pty(b"working\r\n", || unreachable!("no report, so no question"));
        for read in reads {
            shadow.write_from_pty(&read, || Some(10));
        }
        // The sender still owns the pty, so the foreground fallback cannot be what clears.
        let replay = shadow.replay_for(Some(10));
        assert_eq!(
            (has(&replay, BUSY), has(&replay, IDLE)),
            (busy, !busy),
            "{case}"
        );
    }
}

/// A command end with no report held asks the pty nothing, rather than once per prompt.
/// Value: protects=no foreground-group syscall per command when nothing reported; fails_when=a command end marks the slot fresh unconditionally; why_new=the guard is new; seam=none
#[test]
fn a_command_end_with_no_report_asks_nothing() {
    let mut shadow = Shadow::new(80, 24);
    shadow.write_from_pty(b"$ make\r\n\x1b]133;D;0\x07", || {
        unreachable!("no report, so no question")
    });
}

/// What libghostty answers `OSC 7501 ; ?` with, before the probe's own terminator.
const ANSWER: &[u8] =
    b"\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth";

/// Every probe is answered, each with its own terminator: Claude Code probes with BEL, and
/// again on every full redraw (Step 0).
#[test]
fn a_probe_is_answered_with_its_own_terminator() {
    let mut shadow = Shadow::new(80, 24);
    for terminator in [b"\x07".as_slice(), b"\x1b\\"] {
        let probe = [b"\x1b]7501;?".as_slice(), terminator].concat();
        let (replies, _) = shadow.write_from_pty(&probe, || Some(1));
        assert_eq!(replies, [ANSWER, terminator].concat());
    }
}

/// Value: protects=only the 7501 answer reaches the pty, never a DA1, DSR or colour answer the attached client also gives; fails_when=the WRITE_PTY filter is dropped or loosened; why_new=two answers to one query corrupt the program's input; seam=none
#[test]
fn only_the_program_status_answer_is_queued() {
    let mut shadow = Shadow::new(80, 24);
    let (replies, _) = shadow
        .write_from_pty(b"\x1b]7501;?\x07\x1b[c\x1b[6n\x1b[5n\x1b]11;?\x07", || {
            Some(1)
        });
    assert_eq!(replies, [ANSWER, b"\x07"].concat());
}

/// A probe cut across reads is answered once, when it completes.
#[test]
fn a_split_probe_is_answered_once() {
    let mut shadow = Shadow::new(80, 24);
    let probe = b"\x1b]7501;?\x1b\\";
    let mut replies = Vec::new();
    for byte in probe {
        replies.extend(shadow.write_from_pty(&[*byte], || Some(1)).0);
    }
    assert_eq!(replies, [ANSWER, b"\x1b\\"].concat());
}

/// `write` is for screens that are not the live pty's: it answers nothing, and leaves nothing
/// behind for the next live write to answer.
#[test]
fn write_answers_nothing() {
    let mut shadow = Shadow::new(80, 24);
    shadow.write(b"\x1b]7501;?\x07\x1b]7501;state=blocked\x07");
    let (replies, changed) = shadow.write_from_pty(b"x", || Some(1));
    assert!(replies.is_empty());
    assert_eq!(changed, None);
}

/// A probe and a report in one write never alert: the program printing them never read the
/// answer.
#[test]
fn a_probe_and_a_report_written_together_never_alert() {
    let mut shadow = Shadow::new(80, 24);
    shadow.write_from_pty(b"\x1b]7501;?\x07\x1b]7501;state=blocked\x07", || Some(0));
    let id = crate::terminal::session::SessionId([0; 16]);
    let status: serde_json::Value =
        serde_json::from_slice(&shadow.status().unwrap().event(id, id)).unwrap();
    assert_eq!(status["records"][0]["notify"], false);
}

/// A report reaches the store with the foreground group as its sender, and a prompt ends it.
#[test]
fn reports_reach_the_store_and_a_prompt_ends_them() {
    let mut shadow = Shadow::new(80, 24);
    shadow.write_from_pty(b"\x1b]7501;?\x07", || Some(0));
    let (_, changed) = shadow.write_from_pty(
        b"\x1b]7501;state=blocked:kind=permission:app=claude-code:msg=QXBwbHk/\x07",
        || Some(0),
    );
    assert_eq!(changed, Some(true), "a record entered blocked");
    let event = |shadow: &mut Shadow| -> serde_json::Value {
        let id = crate::terminal::session::SessionId([0; 16]);
        serde_json::from_slice(&shadow.status().unwrap().event(id, id)).unwrap()
    };
    let status = event(&mut shadow);
    assert_eq!(status["reporting"], true);
    assert_eq!(status["records"][0]["message"], "Apply?");
    assert_eq!(status["records"][0]["notify"], true, "the prober reported");
    let (_, changed) = shadow.write_from_pty(b"\x1b]133;A\x07$ ", || Some(0));
    assert_eq!(changed, Some(false));
    let status = event(&mut shadow);
    assert_eq!(status["records"], serde_json::json!([]));
    assert_eq!(status["reporting"], false);
}
