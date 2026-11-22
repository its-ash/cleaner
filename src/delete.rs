//! Safe deletion: every path is re-validated right before it is removed, and
//! can go to the Trash instead of being deleted permanently.

use crate::{global, rules};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    /// `rm -rf`, frees space immediately.
    Permanent,
    /// Move to the Trash (Finder "Put Back" works); frees space when the Trash is emptied.
    Trash,
}

/// What a validated path is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Validated {
    pub category: &'static str,
    pub description: &'static str,
}

/// Refuses anything that is not, right now, a folder the rules would match
/// (or a known global cache). Guards against stale scan results and against
/// a front-end sending arbitrary paths.
pub fn validate(path: &Path, home: Option<&Path>) -> Result<Validated, String> {
    validate_with(path, home, &[])
}

/// [`validate`], also accepting folders matched by user-defined `extra` rules.
pub fn validate_with(
    path: &Path,
    home: Option<&Path>,
    extra: &[&'static rules::Rule],
) -> Result<Validated, String> {
    if !path.is_absolute() {
        return Err("path is not absolute".into());
    }
    let md = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if md.file_type().is_symlink() {
        return Err("is a symbolic link".into());
    }
    if !md.is_dir() {
        return Err("is not a folder".into());
    }
    match fs::canonicalize(path) {
        Ok(c) if c == path => {}
        Ok(_) => return Err("path goes through a symbolic link".into()),
        Err(e) => return Err(e.to_string()),
    }
    if path.parent().is_none() || home.is_some_and(|h| path == h) {
        return Err("refusing to delete a root or home folder".into());
    }
    if let Some(h) = home
        && let Some((label, _)) = global::caches(h).into_iter().find(|(_, p)| p == path)
    {
        return Ok(Validated {
            category: "global",
            description: label,
        });
    }
    let mut all = rules::all();
    all.extend_from_slice(extra);
    match rules::match_existing(path, &all) {
        Some(rule) => Ok(Validated {
            category: rule.category,
            description: rule.description,
        }),
        None => Err("no longer matches any cleaning rule (project marker missing?)".into()),
    }
}

pub fn delete(path: &Path, method: Method) -> io::Result<()> {
    delete_reporting(path, method).map(|_| ())
}

/// Deletes `path`; for [`Method::Trash`] also returns where the folder now is
/// inside the Trash (when Finder reports it), so the move can be undone.
pub fn delete_reporting(path: &Path, method: Method) -> io::Result<Option<PathBuf>> {
    match method {
        Method::Permanent => remove(path).map(|_| None),
        Method::Trash => trash_locating(path),
    }
}

/// Moves `path` to the Trash through Finder (so "Put Back" keeps working) and
/// returns its new location. Falls back to the `trash` crate when the
/// location can't be read, e.g. for a non-UTF-8 path.
#[cfg(target_os = "macos")]
fn trash_locating(path: &Path) -> io::Result<Option<PathBuf>> {
    let Some(p) = path.to_str() else {
        return trash::delete(path)
            .map(|_| None)
            .map_err(|e| io::Error::other(e.to_string()));
    };
    let quoted = p.replace('\\', "\\\\").replace('"', "\\\"");
    let out = Command::new("osascript")
        .arg("-e")
        .arg(format!(
            "tell application \"Finder\" to set r to delete (POSIX file \"{quoted}\")"
        ))
        .arg("-e")
        .arg("return POSIX path of (r as alias)")
        .output()?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(io::Error::other(if err.is_empty() {
            "Finder could not move it to the Trash".into()
        } else {
            err
        }));
    }
    let reported = String::from_utf8_lossy(&out.stdout)
        .trim()
        .trim_end_matches('/')
        .to_string();
    Ok((!reported.is_empty())
        .then(|| PathBuf::from(reported))
        .filter(|t| is_in_trash(t)))
}

#[cfg(not(target_os = "macos"))]
fn trash_locating(path: &Path) -> io::Result<Option<PathBuf>> {
    trash::delete(path)
        .map(|_| None)
        .map_err(|e| io::Error::other(e.to_string()))
}

/// True for paths inside a Trash folder: `~/.Trash/…` or `<volume>/.Trashes/<uid>/…`.
pub fn is_in_trash(path: &Path) -> bool {
    use std::path::Component;
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
    {
        return false;
    }
    let names: Vec<_> = path
        .components()
        .filter_map(|c| match c {
            Component::Normal(n) => Some(n.to_string_lossy()),
            _ => None,
        })
        .collect();
    // Needs at least one level below the Trash folder itself.
    names.iter().enumerate().any(|(i, n)| match n.as_ref() {
        ".Trash" => i + 1 < names.len(),
        ".Trashes" => i + 2 < names.len(),
        _ => false,
    })
}

/// Moves a folder back out of the Trash to where it was. Refuses to overwrite
/// anything, to restore from outside a Trash folder, or to create missing parents.
pub fn restore(trashed: &Path, original: &Path) -> Result<(), String> {
    if !original.is_absolute() {
        return Err("original location is not absolute".into());
    }
    if !is_in_trash(trashed) {
        return Err("is not inside the Trash".into());
    }
    let md = fs::symlink_metadata(trashed)
        .map_err(|_| "is no longer in the Trash (emptied or moved?)".to_string())?;
    if md.file_type().is_symlink() || !md.is_dir() {
        return Err("the item in the Trash is not a folder".into());
    }
    if fs::symlink_metadata(original).is_ok() {
        return Err("something already exists at the original location".into());
    }
    let parent = original
        .parent()
        .ok_or("original location has no parent folder")?;
    if !parent.is_dir() {
        return Err("the original parent folder no longer exists".into());
    }
    fs::rename(trashed, original).map_err(|e| e.to_string())
}

/// `remove_dir_all`, but tolerant of already-gone folders and of read-only
/// trees (Go module cache, Gradle, Bazel).
pub fn remove(path: &Path) -> io::Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied => {
            make_writable(path);
            fs::remove_dir_all(path)
        }
        Err(e) => Err(e),
    }
}

#[cfg(unix)]
fn make_writable(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(md) = fs::symlink_metadata(path) else {
        return;
    };
    if !md.is_dir() {
        return;
    }
    let mut perms = md.permissions();
    perms.set_mode(perms.mode() | 0o700);
    let _ = fs::set_permissions(path, perms);
    if let Ok(rd) = fs::read_dir(path) {
        for e in rd.flatten() {
            make_writable(&e.path());
        }
    }
}

#[cfg(not(unix))]
fn make_writable(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmp() -> PathBuf {
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p =
            std::env::temp_dir().join(format!("cleaner-del-{}-{nanos}-{n}", std::process::id()));
        fs::create_dir_all(&p).unwrap();
        fs::canonicalize(p).unwrap()
    }

    #[test]
    fn validates_against_rules() {
        let root = tmp();
        fs::create_dir_all(root.join("rs/target/debug")).unwrap();
        fs::write(root.join("rs/Cargo.toml"), "").unwrap();
        fs::create_dir_all(root.join("notes/target")).unwrap();

        let ok = validate(&root.join("rs/target"), None).unwrap();
        assert_eq!(ok.category, "rust");
        assert!(
            validate(&root.join("notes/target"), None).is_err(),
            "no marker"
        );
        assert!(
            validate(&root.join("rs"), None).is_err(),
            "not a build folder"
        );
        assert!(validate(Path::new("relative/target"), None).is_err());
        assert!(
            validate(&root.join("rs/target/../target"), None).is_err(),
            "not canonical"
        );
        assert!(validate(&root.join("missing/target"), None).is_err());

        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(root.join("rs/target"), root.join("rs/link")).unwrap();
            assert!(validate(&root.join("rs/link"), None).is_err());
        }

        // Marker removed after the scan: refused.
        fs::remove_file(root.join("rs/Cargo.toml")).unwrap();
        assert!(validate(&root.join("rs/target"), None).is_err());
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn custom_rules_validate() {
        let root = tmp();
        fs::create_dir_all(root.join("php/vendor")).unwrap();
        fs::write(root.join("php/composer.json"), "{}").unwrap();
        assert!(validate(&root.join("php/vendor"), None).is_err());
        let r = rules::parse_custom("vendor:composer.json").unwrap();
        assert_eq!(
            validate_with(&root.join("php/vendor"), None, &[r])
                .unwrap()
                .category,
            rules::CUSTOM
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn trash_paths() {
        assert!(is_in_trash(Path::new("/Users/me/.Trash/node_modules")));
        assert!(is_in_trash(Path::new("/Volumes/Disk/.Trashes/501/target")));
        assert!(!is_in_trash(Path::new("/Users/me/.Trash")));
        assert!(!is_in_trash(Path::new("/Volumes/Disk/.Trashes/501")));
        assert!(!is_in_trash(Path::new("/Users/me/code/target")));
        assert!(!is_in_trash(Path::new("/Users/me/.Trash/../code")));
        assert!(!is_in_trash(Path::new("relative/.Trash/x")));
    }

    #[test]
    fn restore_is_careful() {
        let root = tmp();
        let trash = root.join(".Trash");
        fs::create_dir_all(trash.join("node_modules/pkg")).unwrap();
        fs::create_dir_all(root.join("web")).unwrap();
        let original = root.join("web/node_modules");

        assert!(
            restore(&root.join("web"), &original).is_err(),
            "not from a Trash folder"
        );
        assert!(
            restore(&trash.join("node_modules"), &root.join("gone/node_modules")).is_err(),
            "missing parent"
        );
        fs::create_dir_all(&original).unwrap();
        assert!(
            restore(&trash.join("node_modules"), &original).is_err(),
            "would overwrite"
        );
        fs::remove_dir(&original).unwrap();

        restore(&trash.join("node_modules"), &original).unwrap();
        assert!(original.join("pkg").is_dir());
        assert!(!trash.join("node_modules").exists());
        assert!(
            restore(&trash.join("node_modules"), &original).is_err(),
            "already restored"
        );
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn removes_read_only_trees() {
        let root = tmp();
        let dir = root.join("ro/inner");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("f"), "x").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&dir, fs::Permissions::from_mode(0o500)).unwrap();
        }
        remove(&root.join("ro")).unwrap();
        assert!(!root.join("ro").exists());
        remove(&root.join("ro")).unwrap(); // already gone is fine
        fs::remove_dir_all(&root).unwrap();
    }
}
