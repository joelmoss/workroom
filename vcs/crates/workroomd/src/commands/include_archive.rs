//! `workroom include-archive`: a root's included files (#367) written to a tar, which the app
//! streams into a remote workroom's checkout on its host (`tar -x -k -p`). The tar goes to
//! `--output`, so stdout stays one envelope (ADR 0013): the archived paths, their count and size,
//! each file that couldn't be read, and the symlinks skipped.
//!
//! The included files are the regular files that a pattern in the root's include file matches
//! and that git ignores in the root, found with the same two git calls as the Go CLI. A symlink is
//! never one, so nothing outside the root is ever archived. The tar is laid out as Go's
//! `archive/tar` writes it in its PAX format: each member a regular file with its permission bits,
//! size and mtime, owned by uid and gid 0 with no owner names, and a pax header only when an mtime
//! with nanoseconds, a path that isn't ASCII or fits no ustar name and prefix, or a size over the
//! header's needs one (`member_headers`).

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;

use serde::Serialize;

use super::config::{self, os_error};
use super::kind::CliError;
use super::log::go_lossy;
use super::{Args, Context, Outcome};

/// The root's include file: `.gitignore`-style patterns naming the gitignored files every new
/// workroom gets a copy of.
const INCLUDE_FILE: &str = ".worktreeinclude";

#[derive(Serialize)]
struct Payload {
    bytes: u64,
    count: usize,
    paths: Vec<String>,
    skipped: Vec<String>,
    warnings: Vec<String>,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    // `--output` is a required flag, so the parser has refused a run without it.
    let output = args.value_or_default("output");
    match archive(context, args, output) {
        Ok(outcome) => outcome,
        Err(message) => Outcome::Failed(CliError::internal(message)),
    }
}

/// As Go orders it: the project, then its included files, and only then the tar, so a failed
/// listing leaves no tar behind.
fn archive(context: &Context, args: &Args, output: &str) -> Result<Outcome, String> {
    // A `--project` that doesn't exist stays only made absolute; it has no include file, so it
    // archives nothing.
    let root = PathBuf::from(
        match args.value("project").filter(|project| !project.is_empty()) {
            Some(project) => config::canonical_path(project, context)?,
            None => config::getwd(context)?,
        },
    );
    let included = included_files(&root)?;
    let file = File::options()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(output)
        .map_err(|error| format!("open {output}: {}", os_error(&error)))?;
    let written = write_archive(&root, &included.files, file)?;
    if context.json {
        let payload = Payload {
            bytes: written.bytes,
            count: written.archived.len(),
            paths: written.archived.iter().map(|path| go_lossy(path)).collect(),
            skipped: included
                .symlinks
                .iter()
                .map(|path| go_lossy(path))
                .collect(),
            warnings: written.failures,
        };
        return Ok(Outcome::Success(super::envelope::success(
            "include-archive",
            &payload,
        )));
    }
    let stdout = format!("Archived {} files to {output}\n", written.archived.len());
    let stderr: String = written
        .failures
        .iter()
        .map(|failure| format!("{failure}\n"))
        .collect();
    Ok(Outcome::PrintedWithErrors { stdout, stderr })
}

/// What the root's include file matches: the regular files to archive, and the symlinks that
/// matched but are never archived. Both are paths relative to the root, as git's bytes, sorted.
#[derive(Default)]
struct Included {
    files: Vec<Vec<u8>>,
    symlinks: Vec<Vec<u8>>,
}

/// The files the include file matches among the ones git ignores in `root`: those the patterns
/// name that git doesn't track, then those of them that git ignores. None when there is no include
/// file. A match that is neither a regular file nor a symlink, or that is gone, is dropped.
fn included_files(root: &Path) -> Result<Included, String> {
    let patterns = root.join(INCLUDE_FILE);
    match std::fs::metadata(&patterns) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Included::default()),
        Err(error) => {
            return Err(format!("stat {}: {}", patterns.display(), os_error(&error)));
        }
    }
    let exclude_from = [b"--exclude-from=", patterns.as_os_str().as_bytes()].concat();
    let listed = git(
        root,
        &[
            OsStr::new("ls-files"),
            OsStr::new("-z"),
            OsStr::new("--others"),
            OsStr::new("--ignored"),
            OsStr::from_bytes(&exclude_from),
        ],
        None,
    )?;
    let candidates = split_nul(&listed.stdout);
    if candidates.is_empty() {
        return Ok(Included::default());
    }
    let mut stdin = candidates.join(&b'\0');
    stdin.push(b'\0');
    let ignored = git(
        root,
        &[
            OsStr::new("check-ignore"),
            OsStr::new("-z"),
            OsStr::new("--stdin"),
        ],
        Some(stdin),
    );
    let ignored = match ignored {
        Ok(ignored) => ignored,
        // check-ignore exits 1 when it ignores none of them.
        Err(GitFailure { code: Some(1), .. }) => return Ok(Included::default()),
        Err(failure) => return Err(failure.message),
    };
    let mut matched = split_nul(&ignored.stdout);
    matched.sort();
    let mut included = Included::default();
    for path in matched {
        match std::fs::symlink_metadata(root.join(OsStr::from_bytes(&path))) {
            Ok(metadata) if metadata.file_type().is_file() => included.files.push(path),
            Ok(metadata) if metadata.file_type().is_symlink() => included.symlinks.push(path),
            _ => {}
        }
    }
    Ok(included)
}

fn split_nul(bytes: &[u8]) -> Vec<Vec<u8>> {
    bytes
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .map(<[u8]>::to_vec)
        .collect()
}

struct GitOutput {
    stdout: Vec<u8>,
}

/// A git run that failed: its exit code when it exited, and the message to report.
struct GitFailure {
    code: Option<i32>,
    message: String,
}

impl From<GitFailure> for String {
    fn from(failure: GitFailure) -> String {
        failure.message
    }
}

/// Runs git in `root` with `stdin`, its whole stdout kept (an include of `node_modules/` lists a
/// lot), in the environment the Go CLI gives it (`git::command`). The failure's message is Go's:
/// `git <subcommand>: exit status <code>: <stderr>`.
fn git(root: &Path, args: &[&OsStr], stdin: Option<Vec<u8>>) -> Result<GitOutput, GitFailure> {
    let subcommand = args[0].to_string_lossy().into_owned();
    let mut command = super::git::command(root);
    command
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if stdin.is_some() {
        command.stdin(Stdio::piped());
    }
    let failure = |code, detail: String, stderr: &[u8]| GitFailure {
        code,
        message: format!(
            "git {subcommand}: {detail}: {}",
            go_lossy(stderr.trim_ascii())
        ),
    };
    let mut child = command
        .spawn()
        .map_err(|error| failure(None, os_error(&error), b""))?;
    // From its own thread: a listing bigger than the pipe holds blocks until git reads it, and git
    // writes its answers, which `wait_with_output` drains, as it goes.
    let feeder = stdin.map(|bytes| {
        let mut pipe = child.stdin.take().expect("piped stdin");
        std::thread::spawn(move || {
            let _ = pipe.write_all(&bytes);
        })
    });
    let output = child
        .wait_with_output()
        .map_err(|error| failure(None, os_error(&error), b""))?;
    if let Some(feeder) = feeder {
        let _ = feeder.join();
    }
    if output.status.success() {
        return Ok(GitOutput {
            stdout: output.stdout,
        });
    }
    let detail = match output.status.code() {
        Some(code) => format!("exit status {code}"),
        None => format!("{}", output.status),
    };
    Err(failure(output.status.code(), detail, &output.stderr))
}

/// What writing the tar did: the files archived and their total size, and each file that couldn't
/// be read, as `path: reason`.
struct Written {
    archived: Vec<Vec<u8>>,
    bytes: u64,
    failures: Vec<String>,
}

/// Writes `files` (relative to `root`) to `out` as a tar. A file that can't be opened is reported
/// and the rest are still written, so one unreadable key never costs the others; a path that would
/// land outside the checkout it is extracted into is refused. An error is one that leaves the tar
/// itself unusable.
fn write_archive(root: &Path, files: &[Vec<u8>], out: File) -> Result<Written, String> {
    let mut written = Written {
        archived: Vec::new(),
        bytes: 0,
        failures: Vec::new(),
    };
    let mut builder = tar::Builder::new(BufWriter::new(out));
    for name in files {
        if !is_local(name) {
            written
                .failures
                .push(format!("{}: not a path inside the root", go_lossy(name)));
            continue;
        }
        let path = root.join(OsStr::from_bytes(name));
        let source = match File::open(&path) {
            Ok(source) => source,
            Err(error) => {
                written.failures.push(format!(
                    "{}: open {}: {}",
                    go_lossy(name),
                    go_lossy(path.as_os_str().as_bytes()),
                    os_error(&error)
                ));
                continue;
            }
        };
        written.bytes += append_file(&mut builder, name, &path, source)?;
        written.archived.push(name.clone());
    }
    let mut out = builder
        .into_inner()
        .map_err(|error| format!("write: {}", os_error(&error)))?;
    out.flush()
        .map_err(|error| format!("write: {}", os_error(&error)))?;
    Ok(written)
}

/// Appends `source` as the member `name`, with its permission bits, size and mtime, and returns
/// the size. Exactly the size the header gives is written: a file that grew since is cut there,
/// and one that shrank fails the tar rather than writing a short member.
fn append_file(
    builder: &mut tar::Builder<BufWriter<File>>,
    name: &[u8],
    path: &Path,
    source: File,
) -> Result<u64, String> {
    let shown = || go_lossy(path.as_os_str().as_bytes());
    let metadata = source
        .metadata()
        .map_err(|error| format!("stat {}: {}", shown(), os_error(&error)))?;
    let size = metadata.len();
    let write_error = |error: io::Error| format!("write: {}", os_error(&error));
    let headers = member_headers(
        name,
        metadata.mode() & 0o777,
        size,
        metadata.mtime(),
        metadata.mtime_nsec(),
    );
    if let Some((header, records)) = &headers.pax {
        builder
            .append(header, records.as_slice())
            .map_err(write_error)?;
    }
    let mut contents = Exactly {
        inner: source.take(size),
        left: size,
    };
    builder
        .append(&headers.member, &mut contents)
        .map_err(|error| match error.kind() {
            io::ErrorKind::UnexpectedEof => format!("{}: it shrank while it was archived", shown()),
            _ => write_error(error),
        })?;
    Ok(size)
}

/// The headers Go's writer puts before a member's contents: a pax header and its records when the
/// member needs any, then the member's own.
struct Headers {
    pax: Option<(tar::Header, Vec<u8>)>,
    member: tar::Header,
}

/// A member's headers as Go's `tar.Writer.WriteHeader` writes them for a `tar.FormatPAX` header
/// of a regular file named `name` with `mode`, `size` and an mtime of `secs` and `nanos`
/// (`archive/tar`, `allowedFormats`, `writeUSTARHeader` and `writePAXHeader`).
///
/// Go writes plain USTAR, with no pax header, when nothing needs pax: a whole-second mtime and a
/// size that fit the header's octal fields, and an ASCII name that fits its 100 bytes or splits at
/// a `/` into the 155-byte prefix and the name. Else a pax header carries the records the member
/// needs, sorted by key, and the member's own header the rest, with its name as ASCII in the name
/// field alone and a size or mtime the field can't hold as zero.
fn member_headers(name: &[u8], mode: u32, size: u64, secs: i64, nanos: i64) -> Headers {
    let mtime_fits = fits_in_octal(12, secs);
    let size_fits = i64::try_from(size).is_ok_and(|size| fits_in_octal(12, size));
    let split = split_ustar_path(name);
    let mut member = tar::Header::new_ustar();
    member.set_entry_type(tar::EntryType::Regular);
    let ustar = member.as_ustar_mut().expect("a ustar header");
    format_octal(&mut ustar.mode, i64::from(mode));
    format_octal(&mut ustar.uid, 0);
    format_octal(&mut ustar.gid, 0);
    format_octal(&mut ustar.size, i64::try_from(size).unwrap_or(-1));
    format_octal(&mut ustar.mtime, secs);
    format_octal(&mut ustar.dev_major, 0);
    format_octal(&mut ustar.dev_minor, 0);

    let ascii_fits = name.is_ascii() && name.len() <= ustar.name.len();
    if nanos == 0 && mtime_fits && size_fits && (ascii_fits || split.is_some()) {
        let (prefix, suffix) = split.unwrap_or((b"", name));
        format_string(&mut ustar.name, suffix);
        format_string(&mut ustar.prefix, prefix);
        set_checksum(&mut member);
        return Headers { pax: None, member };
    }

    format_string(&mut ustar.name, &to_ascii(name));
    set_checksum(&mut member);
    let mut records = Vec::new();
    if nanos != 0 || !mtime_fits {
        records.extend(pax_record("mtime", pax_time(secs, nanos).as_bytes()));
    }
    if !ascii_fits {
        records.extend(pax_record("path", name));
    }
    if !size_fits {
        records.extend(pax_record("size", size.to_string().as_bytes()));
    }
    // Go's `writeRawFile`: the name as ASCII, cut to the field and its trailing slashes dropped,
    // and every number zero but the size.
    let mut pax = tar::Header::new_ustar();
    pax.set_entry_type(tar::EntryType::XHeader);
    let ustar = pax.as_ustar_mut().expect("a ustar header");
    let mut pax_name = to_ascii(&pax_header_name(name));
    pax_name.truncate(ustar.name.len());
    format_string(&mut ustar.name, trim_end_slashes(&pax_name));
    format_octal(&mut ustar.mode, 0);
    format_octal(&mut ustar.uid, 0);
    format_octal(&mut ustar.gid, 0);
    format_octal(&mut ustar.size, records.len() as i64);
    format_octal(&mut ustar.mtime, 0);
    set_checksum(&mut pax);
    Headers {
        pax: Some((pax, records)),
        member,
    }
}

/// Go's `splitUSTARPath`: an ASCII name over the 100 bytes the name field holds, split at a `/`
/// into a prefix of at most 155 bytes and a name of at most 100, when it can be.
fn split_ustar_path(name: &[u8]) -> Option<(&[u8], &[u8])> {
    const NAME_SIZE: usize = 100;
    const PREFIX_SIZE: usize = 155;
    let mut length = name.len();
    if length <= NAME_SIZE || !name.is_ascii() {
        return None;
    } else if length > PREFIX_SIZE + 1 {
        length = PREFIX_SIZE + 1;
    } else if name[length - 1] == b'/' {
        length -= 1;
    }
    let slash = name[..length].iter().rposition(|byte| *byte == b'/')?;
    let suffix = name.len() - slash - 1;
    if slash == 0 || suffix > NAME_SIZE || suffix == 0 || slash > PREFIX_SIZE {
        return None;
    }
    Some((&name[..slash], &name[slash + 1..]))
}

/// Go's `toASCII`: `name` without its non-ASCII bytes and NULs.
fn to_ascii(name: &[u8]) -> Vec<u8> {
    name.iter()
        .copied()
        .filter(|byte| byte.is_ascii() && *byte != 0)
        .collect()
}

fn trim_end_slashes(name: &[u8]) -> &[u8] {
    let kept = name
        .iter()
        .rposition(|byte| *byte != b'/')
        .map_or(0, |last| last + 1);
    &name[..kept]
}

/// Go's `formatter.formatString`: `value` copied into `field`, NUL-terminated when it is shorter
/// and cut when it is longer. A cut that ends in `/` ends, with the slashes before it, in a NUL
/// instead, since some readers take a regular file whose name field ends in `/` for a directory.
fn format_string(field: &mut [u8], value: &[u8]) {
    let copied = value.len().min(field.len());
    field[..copied].copy_from_slice(&value[..copied]);
    if value.len() < field.len() {
        field[value.len()] = 0;
    }
    if value.len() > field.len() && field[field.len() - 1] == b'/' {
        let kept = trim_end_slashes(&value[..field.len() - 1]).len();
        field[kept] = 0;
    }
}

/// Go's `formatter.formatOctal`: `value` as octal digits padded with zeros to all but the field's
/// last byte, which is NUL; zero when it doesn't fit.
fn format_octal(field: &mut [u8], value: i64) {
    let value = if fits_in_octal(field.len(), value) {
        value
    } else {
        0
    };
    let digits = field.len() - 1;
    format_string(field, format!("{value:0digits$o}").as_bytes());
}

/// Go's `fitsInOctal`: whether `value` fits a field of `length` bytes as octal and a NUL.
fn fits_in_octal(length: usize, value: i64) -> bool {
    value >= 0 && (length >= 22 || value < 1 << ((length - 1) * 3))
}

/// Seals `header` with its checksum, laid out as Go lays it out: six octal digits, NUL, space.
fn set_checksum(header: &mut tar::Header) {
    header.set_cksum();
    let sum = header.cksum().expect("the checksum just written");
    header
        .as_old_mut()
        .cksum
        .copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
}

/// The name Go gives a member's pax header: `PaxHeaders.0` between its directory and base name.
fn pax_header_name(name: &[u8]) -> Vec<u8> {
    match name.iter().rposition(|byte| *byte == b'/') {
        Some(slash) => [&name[..slash], b"/PaxHeaders.0/", &name[slash + 1..]].concat(),
        None => [b"PaxHeaders.0/", name].concat(),
    }
}

/// One pax record, `"<length> <key>=<value>\n"`, whose length counts itself.
fn pax_record(key: &str, value: &[u8]) -> Vec<u8> {
    let body = key.len() + value.len() + 3;
    let mut length = body + body.to_string().len();
    if length.to_string().len() != body.to_string().len() {
        length = body + length.to_string().len();
    }
    [format!("{length} {key}=").as_bytes(), value, b"\n"].concat()
}

/// A time as a pax record writes it, as Go formats it: seconds, then the nanoseconds without
/// trailing zeros.
fn pax_time(secs: i64, nanos: i64) -> String {
    if nanos == 0 {
        return secs.to_string();
    }
    let (sign, secs, nanos) = if secs < 0 {
        ("-", -(secs + 1), 1_000_000_000 - nanos)
    } else {
        ("", secs, nanos)
    };
    format!("{sign}{secs}.{nanos:09}")
        .trim_end_matches('0')
        .to_string()
}

/// Reads exactly `left` bytes from `inner`, failing with `UnexpectedEof` when it ends sooner.
struct Exactly<R> {
    inner: R,
    left: u64,
}

impl<R: Read> Read for Exactly<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read = self.inner.read(buf)?;
        if read == 0 && self.left > 0 && !buf.is_empty() {
            return Err(io::ErrorKind::UnexpectedEof.into());
        }
        self.left -= read as u64;
        Ok(read)
    }
}

/// Go's `filepath.IsLocal` for a slash-separated relative path: not empty, not absolute, and not
/// climbing out of where it starts once cleaned.
fn is_local(path: &[u8]) -> bool {
    if path.is_empty() || path.starts_with(b"/") {
        return false;
    }
    let mut depth = 0usize;
    for part in path.split(|byte| *byte == b'/') {
        match part {
            b"" | b"." => {}
            b".." if depth == 0 => return false,
            b".." => depth -= 1,
            _ => depth += 1,
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pax_record_counts_its_own_length() {
        // Go's records for a member's mtime and a non-ASCII path (`archive/tar`, PAX format).
        assert_eq!(
            pax_record("mtime", b"1795171844.25602177"),
            b"29 mtime=1795171844.25602177\n"
        );
        assert_eq!(
            pax_record("path", "caf\u{e9}.key".as_bytes()),
            "18 path=caf\u{e9}.key\n".as_bytes()
        );
        // Where counting the length's own digits adds one: the rest is 9 bytes, "10" makes it 11.
        assert_eq!(pax_record("k", b"vvvvv"), b"11 k=vvvvv\n");
    }

    #[test]
    fn a_pax_time_drops_trailing_zeros_as_go_does() {
        assert_eq!(pax_time(1795171844, 256021770), "1795171844.25602177");
        assert_eq!(pax_time(5, 0), "5");
        assert_eq!(pax_time(-2, 500_000_000), "-1.5");
    }

    /// A 512-byte block holding `runs`, each at its offset, and NULs elsewhere.
    fn block(runs: &[(usize, &[u8])]) -> Vec<u8> {
        let mut block = vec![0; 512];
        for (offset, bytes) in runs {
            block[*offset..offset + bytes.len()].copy_from_slice(bytes);
        }
        block
    }

    /// A name whose first 100 bytes end in its directory's `/`: 99 bytes of directory, then
    /// `/x.key`.
    fn cut_at_a_slash() -> Vec<u8> {
        [&b"d".repeat(99)[..], b"/x.key"].concat()
    }

    // The expected blocks are Go 1.27.4's: `archive/tar`'s `Writer.WriteHeader` given
    // `tar.Header{Typeflag: tar.TypeReg, Name: <cut_at_a_slash>, Mode: 0o644, Size: 1, ModTime:
    // <the mtime>, Format: tar.FormatPAX}`, each block of the tar it wrote printed as its runs of
    // non-NUL bytes with their offsets.

    /// With nanoseconds the member needs pax, and the 100 bytes of the name its header's field
    /// holds end in `/`, which Go writes as a NUL. The pax header's name drops the slash too.
    #[test]
    fn a_name_field_cut_at_a_slash_ends_in_a_nul_as_go_writes_it() {
        let dir = b"d".repeat(99);
        let headers = member_headers(&cut_at_a_slash(), 0o644, 1, 1_700_000_000, 500_000_000);
        let (pax, records) = headers.pax.expect("a pax header");
        assert_eq!(
            pax.as_bytes().to_vec(),
            block(&[
                (0, &dir),
                (100, b"0000000"),
                (108, b"0000000"),
                (116, b"0000000"),
                (124, b"00000000211"),
                (136, b"00000000000"),
                (148, b"031307"),
                (155, b" x"),
                (257, b"ustar"),
                (263, b"00"),
            ])
        );
        assert_eq!(
            records,
            [
                &b"22 mtime=1700000000.5\n115 path="[..],
                &cut_at_a_slash(),
                b"\n"
            ]
            .concat()
        );
        assert_eq!(
            headers.member.as_bytes().to_vec(),
            block(&[
                (0, &dir),
                (100, b"0000644"),
                (108, b"0000000"),
                (116, b"0000000"),
                (124, b"00000000001"),
                (136, b"14524770400"),
                (148, b"032514"),
                (155, b" 0"),
                (257, b"ustar"),
                (263, b"00"),
                (329, b"0000000"),
                (337, b"0000000"),
            ])
        );
    }

    /// With a whole-second mtime nothing needs pax, so Go writes plain USTAR, the name split at its
    /// last `/` that fits into the prefix and the name fields.
    #[test]
    fn a_long_name_that_splits_needs_no_pax_header_as_go_writes_it() {
        let headers = member_headers(&cut_at_a_slash(), 0o644, 1, 1_700_000_000, 0);
        assert!(headers.pax.is_none());
        assert_eq!(
            headers.member.as_bytes().to_vec(),
            block(&[
                (0, b"x.key"),
                (100, b"0000644"),
                (108, b"0000000"),
                (116, b"0000000"),
                (124, b"00000000001"),
                (136, b"14524770400"),
                (148, b"033473"),
                (155, b" 0"),
                (257, b"ustar"),
                (263, b"00"),
                (329, b"0000000"),
                (337, b"0000000"),
                (345, &b"d".repeat(99)),
            ])
        );
    }

    #[test]
    fn a_ustar_path_splits_as_go_splits_it() {
        let long =
            |dir: usize, file: usize| [b"d".repeat(dir), b"/".to_vec(), b"f".repeat(file)].concat();
        assert_eq!(split_ustar_path(b"short/name"), None);
        assert_eq!(
            split_ustar_path(&long(99, 5)),
            Some((&b"d".repeat(99)[..], &b"fffff"[..]))
        );
        // The prefix holds 155 bytes and the name 100.
        assert!(split_ustar_path(&long(155, 1)).is_some());
        assert_eq!(split_ustar_path(&long(156, 1)), None);
        assert_eq!(split_ustar_path(&long(1, 101)), None);
        // Not ASCII, or no `/` to split at.
        assert_eq!(
            split_ustar_path(&[&long(99, 5)[..], "\u{e9}".as_bytes()].concat()),
            None
        );
        assert_eq!(split_ustar_path(&b"d".repeat(101)), None);
    }

    #[test]
    fn only_a_path_inside_the_root_is_local() {
        for local in ["a", "a/b", "a/../b", "./a"] {
            assert!(is_local(local.as_bytes()), "{local}");
        }
        for outside in ["", "/a", "..", "../a", "a/../../b"] {
            assert!(!is_local(outside.as_bytes()), "{outside}");
        }
    }
}
