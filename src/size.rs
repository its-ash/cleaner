//! Disk usage calculation and human-readable formatting.

use rayon::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::path::Path;
use std::sync::Mutex;

/// Tracks hard-linked inodes so they are only counted once (pnpm, etc.).
#[derive(Default)]
pub struct Seen(Mutex<HashSet<(u64, u64)>>);

/// Bytes on disk and number of files under a directory.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub bytes: u64,
    pub files: u64,
}

impl std::ops::Add for Stats {
    type Output = Stats;
    fn add(self, o: Stats) -> Stats {
        Stats {
            bytes: self.bytes + o.bytes,
            files: self.files + o.files,
        }
    }
}

impl std::iter::Sum for Stats {
    fn sum<I: Iterator<Item = Stats>>(iter: I) -> Stats {
        iter.fold(Stats::default(), |a, b| a + b)
    }
}

pub fn dir_size(path: &Path, seen: &Seen) -> u64 {
    dir_stats(path, seen).bytes
}

pub fn dir_stats(path: &Path, seen: &Seen) -> Stats {
    let Ok(read_dir) = fs::read_dir(path) else {
        return Stats::default();
    };
    let entries: Vec<_> = read_dir.flatten().collect();
    entries
        .par_iter()
        .map(|e| {
            // DirEntry::metadata does not follow symlinks.
            let Ok(md) = e.metadata() else {
                return Stats::default();
            };
            let own = Stats {
                bytes: disk_usage(&md, seen),
                files: u64::from(!md.is_dir()),
            };
            if md.is_dir() {
                own + dir_stats(&e.path(), seen)
            } else {
                own
            }
        })
        .sum()
}

#[cfg(unix)]
fn disk_usage(md: &fs::Metadata, seen: &Seen) -> u64 {
    use std::os::unix::fs::MetadataExt;
    if !md.is_dir() && md.nlink() > 1 && !seen.0.lock().unwrap().insert((md.dev(), md.ino())) {
        return 0;
    }
    md.blocks() * 512
}

#[cfg(not(unix))]
fn disk_usage(md: &fs::Metadata, _seen: &Seen) -> u64 {
    md.len()
}

pub fn human(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

#[cfg(test)]
mod tests {
    use super::human;

    #[test]
    fn formats_sizes() {
        assert_eq!(human(0), "0 B");
        assert_eq!(human(1023), "1023 B");
        assert_eq!(human(1536), "1.5 KB");
        assert_eq!(human(5 * 1024 * 1024 * 1024), "5.0 GB");
    }
}
