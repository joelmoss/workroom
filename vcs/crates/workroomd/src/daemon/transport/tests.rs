use super::*;

#[test]
fn a_pipe_pair_carries_bytes_both_ways() {
    let pair = PipeTransport::pair().expect("pair");
    let (mut daemon_reader, mut daemon_writer) = pair.daemon.split().expect("split");
    let mut client_reader = pair.client_reader;
    let mut client_writer = pair.client_writer;

    client_writer.write_all(b"to the daemon").expect("write");
    let mut buffer = [0u8; 32];
    let n = daemon_reader.read(&mut buffer).expect("read");
    assert_eq!(&buffer[..n], b"to the daemon");

    daemon_writer.write_all(b"to the client").expect("write");
    let n = client_reader.read(&mut buffer).expect("read");
    assert_eq!(&buffer[..n], b"to the client");
}

/// A pipe has no message boundaries: a write can arrive split, which is the property that
/// makes it a fair stand-in for a remote stream rather than a convenience.
#[test]
fn reads_can_be_shorter_than_writes() {
    let pair = PipeTransport::pair().expect("pair");
    let (mut daemon_reader, _writer) = pair.daemon.split().expect("split");
    let mut client_writer = pair.client_writer;

    client_writer.write_all(b"0123456789").expect("write");
    let mut small = [0u8; 4];
    let n = daemon_reader.read(&mut small).expect("read");
    assert_eq!(n, 4, "a small buffer takes a prefix, not the whole write");
    assert_eq!(&small, b"0123");
}

#[test]
fn closing_the_far_end_reports_eof() {
    let pair = PipeTransport::pair().expect("pair");
    let (mut daemon_reader, _writer) = pair.daemon.split().expect("split");
    close(&pair.client_writer);
    let mut buffer = [0u8; 8];
    assert_eq!(daemon_reader.read(&mut buffer).expect("read"), 0);
}
