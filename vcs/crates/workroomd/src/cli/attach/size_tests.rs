use super::*;

const WINDOW: Size = Size {
    columns: 100,
    rows: 30,
    x_pixels: 1000,
    y_pixels: 600,
};

/// Value: protects=moving a window between displays reaches the daemon (#551);
/// fails_when=only rows and columns are compared; why_new=the poll loop had no test;
/// seam=size_to_send; no_claim=the kernel's report (pty tests cover it)
#[test]
fn a_change_of_pixels_alone_is_sent() {
    let moved = Size {
        x_pixels: 2000,
        y_pixels: 1200,
        ..WINDOW
    };
    assert_eq!(size_to_send(WINDOW, moved), Some(moved));
}

#[test]
fn no_change_and_no_terminal_send_nothing() {
    assert_eq!(size_to_send(WINDOW, WINDOW), None);
    assert_eq!(size_to_send(WINDOW, Size::default()), None);
}
