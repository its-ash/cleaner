//! Cheap facts about a git repository, used to avoid cleaning projects
//! someone is actively working on.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;
use std::time::SystemTime;

/// A real `git` binary. Deliberately not `/usr/bin/git`: without the command
/// line tools installed that shim pops up an installer dialog.
pub fn git_binary() -> Option<&'static Path> {
    static GIT: OnceLock<Option<PathBuf>> = OnceLock::new();
    GIT.get_or_init(|| {
        [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.is_file())
    })
    .as_deref()
}

/// Whether the work tree has uncommitted changes (including untracked files).
/// `None` when git isn't available or the command fails.
pub fn is_dirty(repo: &Path) -> Option<bool> {
    let git = git_binary()?;
    let out = Command::new(git)
        .arg("-C")
        .arg(repo)
        .args(["status", "--porcelain", "--untracked-files=normal"])
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status.success().then_some(!out.stdout.is_empty())
}

/// Latest of: HEAD moving (checkout, commit), the reflog, the index (staging).
/// Works without a git binary. `None` if `repo` has no plain `.git` folder.
pub fn last_activity(repo: &Path) -> Option<SystemTime> {
    let dot = repo.join(".git");
    if !dot.is_dir() {
        return None;
    }
    ["HEAD", "logs/HEAD", "index", "FETCH_HEAD"]
        .iter()
        .filter_map(|f| fs::metadata(dot.join(f)).and_then(|m| m.modified()).ok())
        .max()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn activity_from_git_files() {
        let root = std::env::temp_dir().join(format!("cleaner-git-{}", std::process::id()));
        fs::create_dir_all(root.join(".git/logs")).unwrap();
        fs::write(root.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        assert!(last_activity(&root).is_some());
        assert!(last_activity(&root.join("nope")).is_none());
        fs::remove_dir_all(&root).unwrap();
    }
}
