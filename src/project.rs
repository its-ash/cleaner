//! Metadata about the project that owns a matched folder: its name, git
//! repository and when it was last worked on.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// The project folder (the parent of the build folder).
pub fn project_dir(artifact: &Path) -> &Path {
    artifact.parent().unwrap_or(artifact)
}

/// The nearest ancestor of `artifact` containing `.git`, stopping at `stop`
/// (usually the home directory) or after a fixed number of levels.
pub fn git_root(artifact: &Path, stop: Option<&Path>) -> Option<PathBuf> {
    for dir in artifact.ancestors().skip(1).take(12) {
        if stop.is_some_and(|s| dir == s) || dir.parent().is_none() {
            return None;
        }
        if fs::symlink_metadata(dir.join(".git")).is_ok() {
            return Some(dir.to_path_buf());
        }
    }
    None
}

/// When the project was last touched: the newest modification time among the
/// project folder's direct entries, ignoring the build folder itself.
/// Directory mtimes change whenever files are added or removed inside them,
/// so this tracks real activity without walking the whole tree.
pub fn last_modified(artifact: &Path) -> Option<SystemTime> {
    let dir = project_dir(artifact);
    if dir == artifact {
        return fs::symlink_metadata(artifact)
            .and_then(|m| m.modified())
            .ok();
    }
    let skip = artifact.file_name();
    let newest = fs::read_dir(dir)
        .ok()?
        .flatten()
        .filter(|e| Some(e.file_name().as_os_str()) != skip)
        .filter_map(|e| e.metadata().and_then(|m| m.modified()).ok())
        .max();
    newest.or_else(|| fs::symlink_metadata(dir).and_then(|m| m.modified()).ok())
}

pub fn unix_secs(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(e) => -(e.duration().as_secs() as i64),
    }
}

/// Whole days since `t` (0 for the future).
pub fn age_days(t: SystemTime) -> u64 {
    SystemTime::now()
        .duration_since(t)
        .map(|d| d.as_secs() / 86_400)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_git_root_and_mtime() {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("cleaner-proj-{}-{nanos}", std::process::id()));
        let artifact = root.join("repo/app/node_modules");
        fs::create_dir_all(&artifact).unwrap();
        fs::create_dir_all(root.join("repo/.git")).unwrap();
        fs::write(root.join("repo/app/package.json"), "{}").unwrap();

        assert_eq!(git_root(&artifact, None), Some(root.join("repo")));
        assert_eq!(git_root(&artifact, Some(&root.join("repo/app"))), None);
        let m = last_modified(&artifact).unwrap();
        assert!(age_days(m) == 0);
        fs::remove_dir_all(&root).unwrap();
    }
}
