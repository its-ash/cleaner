//! Finds the same npm package version installed in several `node_modules`
//! folders: space a content-addressed store (pnpm) would share.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// One installed package: `node_modules/<name>` or `node_modules/@scope/<name>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Package {
    pub name: String,
    pub version: String,
    pub path: PathBuf,
}

fn read_manifest(dir: &Path) -> Option<(String, String)> {
    let text = fs::read_to_string(dir.join("package.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    let name = v.get("name")?.as_str()?.to_string();
    let version = v.get("version")?.as_str()?.to_string();
    (!name.is_empty() && !version.is_empty()).then_some((name, version))
}

fn real_dirs(dir: &Path) -> Vec<(String, PathBuf)> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    rd.flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir() && !t.is_symlink()))
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
        .collect()
}

/// Top-level packages of one `node_modules` folder. Symlinks (pnpm, workspaces)
/// and tool folders (`.bin`, `.pnpm`, `.cache`) are skipped: they aren't copies.
pub fn packages(node_modules: &Path) -> Vec<Package> {
    let mut out = Vec::new();
    for (name, path) in real_dirs(node_modules) {
        if name.starts_with('.') {
            continue;
        }
        let dirs = if name.starts_with('@') {
            real_dirs(&path)
        } else {
            vec![(name, path)]
        };
        for (_, dir) in dirs {
            if let Some((name, version)) = read_manifest(&dir) {
                out.push(Package {
                    name,
                    version,
                    path: dir,
                });
            }
        }
    }
    out
}

/// Groups packages by `name@version`, keeping those installed more than once.
pub fn group(all: Vec<Package>) -> Vec<((String, String), Vec<PathBuf>)> {
    let mut by: HashMap<(String, String), Vec<PathBuf>> = HashMap::new();
    for p in all {
        by.entry((p.name, p.version)).or_default().push(p.path);
    }
    by.into_iter().filter(|(_, v)| v.len() > 1).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pkg(root: &Path, rel: &str, name: &str, version: &str) {
        let d = root.join(rel);
        fs::create_dir_all(&d).unwrap();
        fs::write(
            d.join("package.json"),
            format!(r#"{{"name":"{name}","version":"{version}"}}"#),
        )
        .unwrap();
    }

    #[test]
    fn finds_duplicates_across_projects() {
        let root = std::env::temp_dir().join(format!("cleaner-dupes-{}", std::process::id()));
        pkg(&root, "a/node_modules/react", "react", "18.2.0");
        pkg(&root, "a/node_modules/@types/node", "@types/node", "20.1.0");
        pkg(&root, "b/node_modules/react", "react", "18.2.0");
        pkg(&root, "b/node_modules/@types/node", "@types/node", "20.1.0");
        pkg(&root, "c/node_modules/react", "react", "17.0.0");
        pkg(&root, "c/node_modules/.bin/x", "x", "1.0.0");

        let mut all = Vec::new();
        for p in ["a", "b", "c"] {
            all.extend(packages(&root.join(p).join("node_modules")));
        }
        assert_eq!(all.len(), 5);
        let mut g = group(all);
        g.sort();
        assert_eq!(g.len(), 2);
        assert_eq!(g[0].0, ("@types/node".to_string(), "20.1.0".to_string()));
        assert_eq!(g[1].0, ("react".to_string(), "18.2.0".to_string()));
        assert_eq!(g[1].1.len(), 2);
        fs::remove_dir_all(&root).unwrap();
    }
}
