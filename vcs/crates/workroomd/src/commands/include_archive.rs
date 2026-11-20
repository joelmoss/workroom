//! `workroom include-archive`: a root's included files (#367) written to a tar, which the app
//! streams into a remote workroom's checkout on its host (`tar -x -k -p`). The tar goes to
//! `--output`, so stdout stays one envelope (ADR 0013): the archived paths, their count and size,
//! each file that couldn't be read, and the symlinks skipped.
//!
//! The included files are the regular files that a pattern in the root's include file matches
//! and that git ignores in the root, found with the same two git calls as the Go CLI. A symlink is
//! never one, so nothing outside the root is ever archived. The tar is laid out as Go's
//! `archive/tar` writes it in its PAX format: each member a regular file with its permission bits,
//! size and mtime, owned by uid and gid 0 with no owner names, and a pax record for an mtime with
//! nanoseconds, a path that isn't ASCII or is over 100 bytes, or a size over the header's.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, BufWriter, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use serde::Serialize;

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
    // `--output` is required, as cobra's `MarkFlagRequired` makes it: checked before the command
    // runs, so the envelope names no command. Given empty, it is set.
    let Some(output) = args.value("output") else {
        return Outcome::Usage(CliError::internal("required flag(s) \"output\" not set"));
    };
    match archive(context, args, output) {
        Ok(outcome) => outcome,
        Err(message) => Outcome::Failed(CliError::internal(message)),
    }
}

/// As Go orders it: the project, then its included files, and only then the tar, so a failed
/// listing leaves no tar behind.
fn archive(context: &Context, args: &Args, output: &str) -> Result<Outcome, String> {
    let root = match args.value("project").filter(|project| !project.is_empty()) {
        Some(project) => canonical_path(project, context)?,
        None => std::env::current_dir().map_err(|error| format!("getwd: {}", go_error(&error)))?,
    };
    let included = included_files(&root)?;
    let file = File::options()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(output)
        .map_err(|error| format!("open {output}: {}", go_error(&error)))?;
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

/// Go's `config.CanonicalPath`, which `--project` goes through: `~` expanded, made absolute and
/// cleaned, then symlink-resolved when it exists. A path that doesn't exist stays as cleaned; it
/// has no include file, so it archives nothing.
fn canonical_path(path: &str, context: &Context) -> Result<PathBuf, String> {
    let expanded = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => {
            let home = context
                .env("HOME")
                .filter(|home| !home.is_empty())
                .ok_or("$HOME is not defined")?;
            format!("{home}{rest}")
        }
        _ => path.to_string(),
    };
    let mut absolute = PathBuf::from("/");
    if !expanded.starts_with('/') {
        absolute = std::env::current_dir().map_err(|error| go_error(&error))?;
    }
    for component in Path::new(&expanded).components() {
        match component {
            Component::Normal(part) => absolute.push(part),
            Component::ParentDir => {
                absolute.pop();
            }
            Component::RootDir | Component::CurDir | Component::Prefix(_) => {}
        }
    }
    Ok(std::fs::canonicalize(&absolute).unwrap_or(absolute))
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
            return Err(format!("stat {}: {}", patterns.display(), go_error(&error)));
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
/// lot). The environment is this process's without the variables that would point git at another
/// repository (`wr_vcs_git::diff::SCRUBBED`), with discovery stopped at `root`
/// (`ceiling_directories`) and no credential prompt, as the Go CLI runs it. The failure's message
/// is Go's: `git <subcommand>: exit status <code>: <stderr>`.
fn git(root: &Path, args: &[&OsStr], stdin: Option<Vec<u8>>) -> Result<GitOutput, GitFailure> {
    let subcommand = args[0].to_string_lossy().into_owned();
    let mut command = Command::new("git");
    command
        .current_dir(root)
        .args(args)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for key in wr_vcs_git::diff::SCRUBBED {
        command.env_remove(key);
    }
    command
        .env_remove("GIT_CEILING_DIRECTORIES")
        .env("GIT_TERMINAL_PROMPT", "0");
    if let Some(ceiling) = wr_vcs_git::diff::ceiling_directories(root) {
        command.env("GIT_CEILING_DIRECTORIES", ceiling);
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
        .map_err(|error| failure(None, go_error(&error), b""))?;
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
        .map_err(|error| failure(None, go_error(&error), b""))?;
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
                    go_error(&error)
                ));
                continue;
            }
        };
        written.bytes += append_file(&mut builder, name, &path, source)?;
        written.archived.push(name.clone());
    }
    let mut out = builder
        .into_inner()
        .map_err(|error| format!("write: {}", go_error(&error)))?;
    out.flush()
        .map_err(|error| format!("write: {}", go_error(&error)))?;
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
        .map_err(|error| format!("stat {}: {}", shown(), go_error(&error)))?;
    let size = metadata.len();
    let (secs, nanos) = (metadata.mtime(), metadata.mtime_nsec());
    let write_error = |error: io::Error| format!("write: {}", go_error(&error));

    // The pax records Go writes, in its order (sorted by key), each only when it's needed.
    let mut records = Vec::new();
    if nanos != 0 || secs < 0 {
        records.extend(pax_record("mtime", pax_time(secs, nanos).as_bytes()));
    }
    if name.len() > 100 || !name.is_ascii() {
        records.extend(pax_record("path", name));
    }
    if size > MAX_OCTAL_SIZE {
        records.extend(pax_record("size", size.to_string().as_bytes()));
    }
    if !records.is_empty() {
        let mut header = ustar_header(&pax_header_name(name), 0, 0);
        header.set_entry_type(tar::EntryType::XHeader);
        header.set_size(records.len() as u64);
        set_checksum(&mut header);
        builder
            .append(&header, records.as_slice())
            .map_err(write_error)?;
    }

    let mut header = ustar_header(
        name,
        metadata.mode() & 0o777,
        u64::try_from(secs).unwrap_or(0),
    );
    header.set_entry_type(tar::EntryType::Regular);
    header.set_size(size);
    // Go writes a regular member's device numbers as octal zeros, and its pax header's as NULs.
    let ustar = header.as_ustar_mut().expect("a ustar header");
    ustar.set_device_major(0);
    ustar.set_device_minor(0);
    set_checksum(&mut header);
    let mut contents = Exactly {
        inner: source.take(size),
        left: size,
    };
    builder
        .append(&header, &mut contents)
        .map_err(|error| match error.kind() {
            io::ErrorKind::UnexpectedEof => format!("{}: it shrank while it was archived", shown()),
            _ => write_error(error),
        })?;
    Ok(size)
}

/// The largest size a ustar header's 11 octal digits hold.
const MAX_OCTAL_SIZE: u64 = 0o77777777777;

/// A ustar header as Go's writer starts one: `name` as ASCII, cut to the 100 bytes the field
/// holds (a pax `path` record carries the whole name), the mode and mtime given, uid and gid 0,
/// and no owner names.
fn ustar_header(name: &[u8], mode: u32, mtime: u64) -> tar::Header {
    let mut header = tar::Header::new_ustar();
    let ascii: Vec<u8> = name
        .iter()
        .copied()
        .filter(u8::is_ascii)
        .take(100)
        .collect();
    let ustar = header.as_ustar_mut().expect("a ustar header");
    ustar.name[..ascii.len()].copy_from_slice(&ascii);
    header.set_mode(mode);
    header.set_uid(0);
    header.set_gid(0);
    header.set_mtime(mtime);
    header
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

/// An I/O error as Go words it: the system's message for its errno, first letter lowercased
/// (`permission denied`), else Rust's own.
fn go_error(error: &io::Error) -> String {
    let Some(code) = error.raw_os_error() else {
        return error.to_string();
    };
    let text = io::Error::from_raw_os_error(code).to_string();
    let text = text
        .strip_suffix(&format!(" (os error {code})"))
        .unwrap_or(&text);
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
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

    #[test]
    fn only_a_path_inside_the_root_is_local() {
        for local in ["a", "a/b", "a/../b", "./a"] {
            assert!(is_local(local.as_bytes()), "{local}");
        }
        for outside in ["", "/a", "..", "../a", "a/../../b"] {
            assert!(!is_local(outside.as_bytes()), "{outside}");
        }
    }

    #[test]
    fn an_io_error_reads_as_gos() {
        let denied = io::Error::from_raw_os_error(libc::EACCES);
        assert_eq!(go_error(&denied), "permission denied");
        let missing = io::Error::from_raw_os_error(libc::ENOENT);
        assert_eq!(go_error(&missing), "no such file or directory");
    }
}
