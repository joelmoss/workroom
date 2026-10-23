//! Becoming a container's remote user (#308).
//!
//! A container workroom's daemon is the container's entrypoint, started as root, because it alone
//! is there to make what the remote user needs before anything runs: the socket's folder and the
//! workspace folder, owned by that user (eng review O1). It then drops to that user for good, so
//! every session, git and lifecycle command runs as the user the devcontainer.json names. Done in
//! the daemon rather than the image: an image may have no `setpriv`, `su` or shell at all.

use std::ffi::{CStr, CString};
use std::io;
use std::path::{Path, PathBuf};

/// A user from the passwd database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub name: String,
    pub uid: libc::uid_t,
    pub gid: libc::gid_t,
    pub home: PathBuf,
}

/// The account `spec` names: a user name, or a numeric `uid[:gid]` (Docker's `--user` forms). A
/// uid with no passwd entry is still an account, with `/` for its home, as Docker treats one.
pub fn lookup(spec: &str) -> io::Result<Account> {
    let (user, group) = match spec.split_once(':') {
        Some((user, group)) => (user, Some(group)),
        None => (spec, None),
    };
    let mut account = match user.parse::<libc::uid_t>() {
        Ok(uid) => entry(Entry::Uid(uid))?.unwrap_or(Account {
            name: uid.to_string(),
            uid,
            gid: uid,
            home: PathBuf::from("/"),
        }),
        Err(_) => entry(Entry::Name(user))?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("no user {user} in /etc/passwd"),
            )
        })?,
    };
    if let Some(group) = group {
        account.gid = group.parse().map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("group {group} is not a number"),
            )
        })?;
    }
    Ok(account)
}

enum Entry<'a> {
    Name(&'a str),
    Uid(libc::uid_t),
}

fn entry(which: Entry) -> io::Result<Option<Account>> {
    // SAFETY: `passwd` is plain C data (integers and pointers), for which all-zero is valid.
    let mut record: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    let mut buffer = vec![0 as libc::c_char; 16 * 1024];
    let rc = match which {
        Entry::Name(name) => {
            let name = CString::new(name)
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a NUL in a user name"))?;
            // SAFETY: every pointer is to a live local sized as passed.
            unsafe {
                libc::getpwnam_r(
                    name.as_ptr(),
                    &mut record,
                    buffer.as_mut_ptr(),
                    buffer.len(),
                    &mut found,
                )
            }
        }
        // SAFETY: as above.
        Entry::Uid(uid) => unsafe {
            libc::getpwuid_r(
                uid,
                &mut record,
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut found,
            )
        },
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if found.is_null() {
        return Ok(None);
    }
    // SAFETY: getpwnam_r/getpwuid_r succeeded, so the strings are NUL-terminated inside `buffer`.
    let text = |pointer: *const libc::c_char| unsafe {
        if pointer.is_null() {
            String::new()
        } else {
            CStr::from_ptr(pointer).to_string_lossy().into_owned()
        }
    };
    Ok(Some(Account {
        name: text(record.pw_name),
        uid: record.pw_uid,
        gid: record.pw_gid,
        home: PathBuf::from(text(record.pw_dir)),
    }))
}

/// `path` with a leading `~/` (or a lone `~`) taken as `home`.
pub fn expand_home(path: &Path, home: &Path) -> PathBuf {
    match path.strip_prefix("~") {
        Ok(rest) => home.join(rest),
        Err(_) => path.to_path_buf(),
    }
}

/// Makes each of `folders` (and anything missing above it, as root's) and gives it to `account`,
/// with `private` ones at 0700; then drops to `account` for good: its groups, its gid, its uid, and
/// `HOME`, `USER` and `LOGNAME` for what the daemon runs. A process that is already `account` (a
/// hand-off's new program, which the drop made) only checks the folders exist.
pub fn become_user(account: &Account, folders: &[(PathBuf, bool)]) -> io::Result<()> {
    // SAFETY: getuid takes nothing and cannot fail.
    let already = unsafe { libc::getuid() } == account.uid;
    for (folder, private) in folders {
        if already {
            std::fs::create_dir_all(folder)?;
            continue;
        }
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(if *private { 0o700 } else { 0o755 })
                .create(folder)?;
        }
        std::os::unix::fs::chown(folder, Some(account.uid), Some(account.gid))?;
        if *private {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    if already {
        return Ok(());
    }
    let name = CString::new(account.name.clone())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "a NUL in a user name"))?;
    // SAFETY: plain syscalls on this process's credentials, groups first while still root.
    unsafe {
        #[cfg(target_os = "macos")]
        let groups = libc::initgroups(name.as_ptr(), account.gid as libc::c_int);
        #[cfg(not(target_os = "macos"))]
        let groups = libc::initgroups(name.as_ptr(), account.gid);
        if groups != 0 {
            return Err(io::Error::last_os_error());
        }
        if libc::setgid(account.gid) != 0 || libc::setuid(account.uid) != 0 {
            return Err(io::Error::last_os_error());
        }
    }
    // SAFETY: the daemon is single-threaded here, before it serves anything.
    unsafe {
        std::env::set_var("HOME", &account.home);
        std::env::set_var("USER", &account.name);
        std::env::set_var("LOGNAME", &account.name);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_leading_tilde_is_the_users_home() {
        let home = Path::new("/home/vscode");
        assert_eq!(
            expand_home(Path::new("~/.local/state/screens"), home),
            PathBuf::from("/home/vscode/.local/state/screens")
        );
        assert_eq!(
            expand_home(Path::new("~"), home),
            PathBuf::from("/home/vscode")
        );
        assert_eq!(expand_home(Path::new("/abs"), home), PathBuf::from("/abs"));
        assert_eq!(
            expand_home(Path::new("~other/x"), home),
            PathBuf::from("~other/x")
        );
    }

    /// The account running the tests, found by its name and by its uid, the same either way; a uid
    /// with a group overrides the group; a uid nobody has is still an account, rooted at `/`.
    #[test]
    fn an_account_is_found_by_name_or_uid() {
        // SAFETY: getuid takes nothing and cannot fail.
        let uid = unsafe { libc::getuid() };
        let by_uid = lookup(&uid.to_string()).unwrap();
        let by_name = lookup(&by_uid.name).unwrap();
        assert_eq!(by_uid, by_name);
        assert!(by_uid.home.is_absolute());
        assert_eq!(lookup(&format!("{uid}:4242")).unwrap().gid, 4242);
        let nobody = lookup("4000000").unwrap();
        assert_eq!((nobody.uid, nobody.home), (4_000_000, PathBuf::from("/")));
        assert!(lookup("no-such-user-workroom").is_err());
    }
}
