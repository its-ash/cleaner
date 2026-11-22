//! Core of `cleaner`: rules, the parallel scanner, size measurement, project
//! metadata and safe deletion. Used by the `cleaner` CLI and by
//! `cleaner-engine`, the JSON back-end of the macOS app.

pub mod delete;
pub mod dupes;
pub mod gitinfo;
pub mod global;
pub mod project;
pub mod rules;
pub mod scan;
pub mod size;

use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// System and app-data locations the scanner never descends into.
pub fn default_excludes(home: Option<&Path>) -> HashSet<PathBuf> {
    let mut set: HashSet<PathBuf> = [
        "/System",
        "/Library",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/private",
        "/dev",
        "/opt",
        "/proc",
        "/sys",
        "/Volumes/Recovery",
    ]
    .iter()
    .map(PathBuf::from)
    .collect();
    if let Some(h) = home {
        set.insert(h.join("Library"));
        set.insert(h.join("Applications"));
        set.insert(h.join(".Trash"));
    }
    set
}

/// Shows `~/…` for paths inside the home directory.
pub fn pretty(path: &Path, home: Option<&Path>) -> String {
    if let Some(h) = home
        && let Ok(rest) = path.strip_prefix(h)
    {
        return format!("~/{}", rest.display());
    }
    path.display().to_string()
}

pub fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(PathBuf::from)
}
