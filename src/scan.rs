//! Parallel directory walker that collects directories matching the rules.

use crate::rules::{self, ParentInfo, Rule};
use rayon::prelude::*;
use std::collections::HashSet;
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub struct ScanOptions {
    pub rules: Vec<&'static Rule>,
    /// Descend into hidden directories (names starting with '.').
    pub hidden: bool,
    /// Directories never descended into or matched.
    pub excludes: HashSet<PathBuf>,
}

/// Live counters a caller can poll from another thread while a scan runs.
#[derive(Default)]
pub struct Progress {
    /// Directories read so far.
    pub dirs: AtomicU64,
    /// Matching folders found so far.
    pub found: AtomicU64,
    /// Set to stop the walk early.
    pub cancel: AtomicBool,
    /// A directory being read right now (best effort, for display).
    pub current: Mutex<Option<PathBuf>>,
}

impl Progress {
    pub fn current(&self) -> Option<PathBuf> {
        self.current.lock().ok().and_then(|c| c.clone())
    }
}

pub fn scan(root: &Path, opts: &ScanOptions) -> Vec<(PathBuf, &'static Rule)> {
    walk(root, opts, &Progress::default())
}

pub fn scan_with_progress(
    root: &Path,
    opts: &ScanOptions,
    progress: &Progress,
) -> Vec<(PathBuf, &'static Rule)> {
    walk(root, opts, progress)
}

/// Removes entries nested inside other entries (overlapping roots) and duplicates.
pub fn dedupe<T>(mut found: Vec<(PathBuf, T)>) -> Vec<(PathBuf, T)> {
    found.sort_by(|a, b| a.0.cmp(&b.0));
    let mut out: Vec<(PathBuf, T)> = Vec::with_capacity(found.len());
    for f in found {
        if out.last().is_some_and(|last| f.0.starts_with(&last.0)) {
            continue;
        }
        out.push(f);
    }
    out
}

fn walk(dir: &Path, opts: &ScanOptions, progress: &Progress) -> Vec<(PathBuf, &'static Rule)> {
    if progress.cancel.load(Ordering::Relaxed) {
        return Vec::new();
    }
    progress.dirs.fetch_add(1, Ordering::Relaxed);
    if let Ok(mut cur) = progress.current.try_lock() {
        *cur = Some(dir.to_path_buf());
    }
    let Ok(read_dir) = fs::read_dir(dir) else {
        return Vec::new(); // permission denied etc. -> skip silently
    };

    let mut names: HashSet<OsString> = HashSet::new();
    let mut subdirs: Vec<OsString> = Vec::new();
    for entry in read_dir.flatten() {
        let name = entry.file_name();
        // file_type() does not follow symlinks, so symlinked dirs are never entered or deleted.
        if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
            subdirs.push(name.clone());
        }
        names.insert(name);
    }

    let parent = ParentInfo { dir, names: &names };
    let mut found = Vec::new();
    let mut descend = Vec::new();

    for name in subdirs {
        let path = dir.join(&name);
        if opts.excludes.contains(&path) {
            continue;
        }
        let name = name.to_string_lossy();
        if let Some(rule) = rules::find_rule(&name, &parent, &opts.rules) {
            progress.found.fetch_add(1, Ordering::Relaxed);
            found.push((path, rule)); // never descend into something we will delete
            continue;
        }
        if name == ".git" || (!opts.hidden && name.starts_with('.')) {
            continue;
        }
        descend.push(path);
    }

    let nested: Vec<_> = descend
        .par_iter()
        .flat_map_iter(|p| walk(p, opts, progress))
        .collect();
    found.extend(nested);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::RULES;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn tmp() -> PathBuf {
        // Tests run in parallel and can read the same clock tick; the counter keeps dirs unique.
        static N: AtomicU64 = AtomicU64::new(0);
        let n = N.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let p =
            std::env::temp_dir().join(format!("cleaner-test-{}-{nanos}-{n}", std::process::id()));
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn touch(p: &Path) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, b"x").unwrap();
    }

    fn opts(aggressive: bool) -> ScanOptions {
        ScanOptions {
            rules: RULES
                .iter()
                .filter(|r| aggressive || !r.aggressive)
                .collect(),
            hidden: false,
            excludes: HashSet::new(),
        }
    }

    fn rel(root: &Path, found: Vec<(PathBuf, &'static Rule)>) -> Vec<String> {
        let mut v: Vec<String> = found
            .into_iter()
            .map(|(p, _)| p.strip_prefix(root).unwrap().to_string_lossy().into_owned())
            .collect();
        v.sort();
        v
    }

    #[test]
    fn matches_only_with_markers() {
        let root = tmp();
        // Rust project
        touch(&root.join("rusty/Cargo.toml"));
        touch(&root.join("rusty/target/debug/app"));
        // Node project with nested node_modules (must be reported once)
        touch(&root.join("web/package.json"));
        touch(&root.join("web/node_modules/a/node_modules/b/index.js"));
        touch(&root.join("web/.next/cache/x"));
        touch(&root.join("web/dist/app.js")); // aggressive only
        // Flutter app with Android + iOS
        touch(&root.join("app/pubspec.yaml"));
        touch(&root.join("app/build/out"));
        touch(&root.join("app/.dart_tool/x"));
        touch(&root.join("app/android/build.gradle"));
        touch(&root.join("app/android/.gradle/x"));
        touch(&root.join("app/android/app/build.gradle"));
        touch(&root.join("app/android/app/build/x"));
        touch(&root.join("app/ios/Podfile"));
        touch(&root.join("app/ios/Pods/x"));
        touch(&root.join("app/ios/Flutter/ephemeral/x"));
        // Things that must NOT match
        touch(&root.join("notes/build/important.txt"));
        touch(&root.join("notes/target/plan.md"));
        touch(&root.join("lib/node_modules/global-pkg/index.js")); // no package.json
        touch(&root.join(".hidden/proj/Cargo.toml"));
        touch(&root.join(".hidden/proj/target/x"));
        // Python cache anywhere
        touch(&root.join("scripts/__pycache__/a.pyc"));

        let found = rel(&root, scan(&root, &opts(false)));
        assert_eq!(
            found,
            vec![
                "app/.dart_tool",
                "app/android/.gradle",
                "app/android/app/build",
                "app/build",
                "app/ios/Flutter/ephemeral",
                "app/ios/Pods",
                "rusty/target",
                "scripts/__pycache__",
                "web/.next",
                "web/node_modules",
            ]
        );

        let aggressive = rel(&root, scan(&root, &opts(true)));
        assert!(aggressive.contains(&"web/dist".to_string()));
        assert!(!aggressive.contains(&"notes/build".to_string()));

        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn respects_excludes() {
        let root = tmp();
        touch(&root.join("a/Cargo.toml"));
        touch(&root.join("a/target/x"));
        touch(&root.join("b/Cargo.toml"));
        touch(&root.join("b/target/x"));
        let mut o = opts(false);
        o.excludes.insert(root.join("a"));
        assert_eq!(rel(&root, scan(&root, &o)), vec!["b/target"]);
        fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn dedupe_drops_nested() {
        let v = vec![
            (PathBuf::from("/a/b/node_modules"), 1),
            (PathBuf::from("/a"), 2),
            (PathBuf::from("/c"), 3),
            (PathBuf::from("/c"), 4),
            (PathBuf::from("/cd"), 5),
        ];
        let out: Vec<PathBuf> = dedupe(v).into_iter().map(|(p, _)| p).collect();
        assert_eq!(
            out,
            vec![
                PathBuf::from("/a"),
                PathBuf::from("/c"),
                PathBuf::from("/cd")
            ]
        );
    }

    #[test]
    fn progress_counts_and_cancel() {
        let root = tmp();
        touch(&root.join("p/Cargo.toml"));
        touch(&root.join("p/target/x"));
        touch(&root.join("q/r/s/file"));
        let progress = Progress::default();
        let found = scan_with_progress(&root, &opts(false), &progress);
        assert_eq!(found.len(), 1);
        assert_eq!(progress.found.load(Ordering::Relaxed), 1);
        assert!(progress.dirs.load(Ordering::Relaxed) >= 4);

        let cancelled = Progress::default();
        cancelled.cancel.store(true, Ordering::Relaxed);
        assert!(scan_with_progress(&root, &opts(false), &cancelled).is_empty());
        fs::remove_dir_all(&root).unwrap();
    }
}
