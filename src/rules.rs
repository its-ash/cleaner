//! Rules that decide which directories are disposable build output.
//!
//! A directory is only matched when its name matches AND its parent directory
//! contains a "marker" proving what kind of project it is. That is what keeps
//! a hand-written `build/` or `target/` folder from being deleted.

use std::collections::HashSet;
use std::ffi::OsString;
use std::path::Path;

#[derive(Clone, Copy, Debug)]
pub enum NameMatch {
    Exact(&'static str),
    Prefix(&'static str),
}

#[derive(Clone, Copy, Debug)]
pub enum Marker {
    /// Always disposable, wherever it appears (e.g. `__pycache__`).
    Always,
    /// Parent directory contains at least one of these files/dirs.
    Files(&'static [&'static str]),
    /// Parent directory contains an entry ending with one of these extensions.
    Ext(&'static [&'static str]),
    /// Parent directory itself has one of these names.
    ParentNamed(&'static [&'static str]),
}

#[derive(Debug)]
pub struct Rule {
    pub name: NameMatch,
    pub category: &'static str,
    pub marker: Marker,
    /// Only active with `--aggressive` (slower to rebuild or occasionally ambiguous).
    pub aggressive: bool,
    pub description: &'static str,
}

pub struct ParentInfo<'a> {
    pub dir: &'a Path,
    pub names: &'a HashSet<OsString>,
}

impl Rule {
    fn name_matches(&self, name: &str) -> bool {
        match self.name {
            NameMatch::Exact(n) => name == n,
            NameMatch::Prefix(p) => name.starts_with(p) && name.len() > p.len(),
        }
    }

    fn marker_matches(&self, parent: &ParentInfo) -> bool {
        match self.marker {
            Marker::Always => true,
            Marker::Files(files) => files
                .iter()
                .any(|f| parent.names.contains(&OsString::from(f))),
            Marker::Ext(exts) => parent.names.iter().any(|n| {
                let n = n.to_string_lossy();
                exts.iter().any(|e| n.ends_with(e))
            }),
            Marker::ParentNamed(names) => parent
                .dir
                .file_name()
                .map(|n| names.iter().any(|x| n == *x))
                .unwrap_or(false),
        }
    }

    /// Name and marker both match.
    pub fn matches(&self, name: &str, parent: &ParentInfo) -> bool {
        self.name_matches(name) && self.marker_matches(parent)
    }

    pub fn display_name(&self) -> String {
        match self.name {
            NameMatch::Exact(n) => n.to_string(),
            NameMatch::Prefix(p) => format!("{p}*"),
        }
    }
}

pub fn find_rule(
    name: &str,
    parent: &ParentInfo,
    rules: &[&'static Rule],
) -> Option<&'static Rule> {
    rules.iter().copied().find(|r| r.matches(name, parent))
}

/// Names of all entries inside `dir` (files and folders, symlinks not followed).
pub fn read_names(dir: &Path) -> HashSet<OsString> {
    std::fs::read_dir(dir)
        .map(|rd| rd.flatten().map(|e| e.file_name()).collect())
        .unwrap_or_default()
}

/// Re-checks an existing directory against `rules` by looking at its parent
/// right now. Used before deleting so a stale or forged path is refused.
pub fn match_existing(path: &Path, rules: &[&'static Rule]) -> Option<&'static Rule> {
    let parent = path.parent()?;
    let name = path.file_name()?.to_string_lossy();
    let names = read_names(parent);
    find_rule(
        &name,
        &ParentInfo {
            dir: parent,
            names: &names,
        },
        rules,
    )
}

/// Every rule, including `--aggressive` ones.
pub fn all() -> Vec<&'static Rule> {
    RULES.iter().collect()
}

// ---- markers ---------------------------------------------------------------

const NODE: Marker = Marker::Files(&["package.json"]);
const CARGO: Marker = Marker::Files(&["Cargo.toml"]);
const MAVEN: Marker = Marker::Files(&["pom.xml"]);
const SBT: Marker = Marker::Files(&["build.sbt"]);
const PUB: Marker = Marker::Files(&["pubspec.yaml"]);
const GRADLE: Marker = Marker::Files(&[
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle",
    "settings.gradle.kts",
]);
const PODS: Marker = Marker::Files(&["Podfile"]);
const XCODE: Marker = Marker::Ext(&[".xcodeproj", ".xcworkspace"]);
const SWIFTPM: Marker = Marker::Files(&["Package.swift"]);
const PYTHON: Marker = Marker::Files(&[
    "pyproject.toml",
    "setup.py",
    "setup.cfg",
    "requirements.txt",
    "Pipfile",
]);
const DOTNET: Marker = Marker::Ext(&[".csproj", ".fsproj", ".vbproj", ".sln"]);
const CMAKE: Marker = Marker::Files(&["CMakeLists.txt"]);
const MIX: Marker = Marker::Files(&["mix.exs"]);
const STACK: Marker = Marker::Files(&["stack.yaml"]);
const CABAL: Marker = Marker::Ext(&[".cabal"]);
const ZIG: Marker = Marker::Files(&["build.zig"]);
const UNITY: Marker = Marker::Files(&["ProjectSettings"]);
const TERRAFORM: Marker = Marker::Ext(&[".tf"]);

const fn rule(
    name: &'static str,
    category: &'static str,
    marker: Marker,
    description: &'static str,
) -> Rule {
    Rule {
        name: NameMatch::Exact(name),
        category,
        marker,
        aggressive: false,
        description,
    }
}

const fn aggressive(
    name: &'static str,
    category: &'static str,
    marker: Marker,
    description: &'static str,
) -> Rule {
    Rule {
        name: NameMatch::Exact(name),
        category,
        marker,
        aggressive: true,
        description,
    }
}

pub static RULES: &[Rule] = &[
    // Node / JS
    rule("node_modules", "node", NODE, "npm/yarn/pnpm dependencies"),
    rule(".next", "node", NODE, "Next.js build"),
    rule(".nuxt", "node", NODE, "Nuxt build"),
    rule(".svelte-kit", "node", NODE, "SvelteKit build"),
    rule(".turbo", "node", NODE, "Turborepo cache"),
    rule(".parcel-cache", "node", NODE, "Parcel cache"),
    rule(".angular", "node", NODE, "Angular cache"),
    rule(".expo", "node", NODE, "Expo cache"),
    rule(".docusaurus", "node", NODE, "Docusaurus build cache"),
    aggressive("dist", "node", NODE, "JS build output"),
    aggressive("build", "node", NODE, "JS build output"),
    aggressive("out", "node", NODE, "JS build output"),
    aggressive(".output", "node", NODE, "Nuxt/Nitro output"),
    aggressive("coverage", "node", NODE, "test coverage report"),
    aggressive(".cache", "node", NODE, "tool cache"),
    // Rust
    rule("target", "rust", CARGO, "Cargo debug/release builds"),
    // JVM
    rule("target", "java", MAVEN, "Maven build output"),
    rule("target", "java", SBT, "sbt build output"),
    // Flutter / Dart
    rule(".dart_tool", "flutter", PUB, "Dart tool cache"),
    rule("build", "flutter", PUB, "Flutter build output"),
    rule(
        "ephemeral",
        "flutter",
        Marker::ParentNamed(&["flutter", "Flutter"]),
        "Flutter generated platform files",
    ),
    // Gradle / Android
    rule("build", "gradle", GRADLE, "Gradle/Android build output"),
    rule(".gradle", "gradle", GRADLE, "Gradle project cache"),
    rule(".cxx", "gradle", GRADLE, "Android NDK build"),
    rule(".kotlin", "gradle", GRADLE, "Kotlin compiler cache"),
    // iOS / macOS
    rule("Pods", "cocoapods", PODS, "CocoaPods dependencies"),
    rule(
        ".symlinks",
        "cocoapods",
        PODS,
        "Flutter iOS plugin symlinks",
    ),
    rule("build", "xcode", XCODE, "Xcode build output"),
    rule("DerivedData", "xcode", Marker::Always, "Xcode derived data"),
    rule(".build", "swift", SWIFTPM, "SwiftPM build output"),
    // Python
    rule("__pycache__", "python", Marker::Always, "bytecode cache"),
    rule(".pytest_cache", "python", Marker::Always, "pytest cache"),
    rule(".mypy_cache", "python", Marker::Always, "mypy cache"),
    rule(".ruff_cache", "python", Marker::Always, "ruff cache"),
    rule(".tox", "python", Marker::Always, "tox environments"),
    rule(".nox", "python", Marker::Always, "nox environments"),
    rule(
        ".hypothesis",
        "python",
        Marker::Always,
        "hypothesis database",
    ),
    aggressive(".venv", "python", PYTHON, "virtualenv"),
    aggressive("venv", "python", PYTHON, "virtualenv"),
    // .NET
    rule("bin", "dotnet", DOTNET, ".NET Debug/Release binaries"),
    rule("obj", "dotnet", DOTNET, ".NET intermediate files"),
    // C / C++
    Rule {
        name: NameMatch::Prefix("cmake-build-"),
        category: "cmake",
        marker: CMAKE,
        aggressive: false,
        description: "CLion debug/release builds",
    },
    aggressive("build", "cmake", CMAKE, "CMake build dir"),
    // Elixir
    rule("_build", "elixir", MIX, "Mix build output"),
    rule("deps", "elixir", MIX, "Mix dependencies"),
    // Haskell
    rule(".stack-work", "haskell", STACK, "Stack build output"),
    rule("dist-newstyle", "haskell", CABAL, "Cabal build output"),
    // Zig
    rule("zig-cache", "zig", ZIG, "Zig cache"),
    rule(".zig-cache", "zig", ZIG, "Zig cache"),
    rule("zig-out", "zig", ZIG, "Zig build output"),
    // Unity
    aggressive("Library", "unity", UNITY, "Unity imported assets cache"),
    aggressive("Temp", "unity", UNITY, "Unity temp files"),
    aggressive("Obj", "unity", UNITY, "Unity intermediate files"),
    // Terraform
    aggressive(
        ".terraform",
        "terraform",
        TERRAFORM,
        "Terraform providers/modules",
    ),
];

/// Category of rules the user defines (`--rule` in `cleaner-engine`).
pub const CUSTOM: &str = "custom";

fn leak(s: &str) -> &'static str {
    Box::leak(s.to_owned().into_boxed_str())
}

/// Builds a user-defined rule from `NAME:MARKER[,MARKER..][:DESCRIPTION]`.
///
/// `NAME` is a folder name, or a prefix ending in `*` (`cmake-build-*`).
/// Each `MARKER` is a file or folder that must sit next to it (`Cargo.toml`),
/// or an extension (`*.csproj`). A marker is required: custom rules follow the
/// same "only with proof of a project" principle as the built-in ones.
///
/// The rule is leaked: it lives for the rest of the process, like `RULES`.
pub fn parse_custom(spec: &str) -> Result<&'static Rule, String> {
    let mut parts = spec.splitn(3, ':');
    let name = parts.next().unwrap_or("").trim();
    let markers: Vec<&str> = parts
        .next()
        .unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|m| !m.is_empty())
        .collect();
    let description = parts
        .next()
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .unwrap_or("custom rule");

    let bad_name =
        |n: &str| n.is_empty() || n == "." || n == ".." || n.contains('/') || n.contains('*');
    let name_match = match name.strip_suffix('*') {
        Some(prefix) if !bad_name(prefix) => NameMatch::Prefix(leak(prefix)),
        None if !bad_name(name) => NameMatch::Exact(leak(name)),
        _ => return Err(format!("custom rule '{spec}': invalid folder name")),
    };
    if matches!(name, ".git" | ".svn" | ".hg") {
        return Err(format!(
            "custom rule '{spec}': refusing to match version control folders"
        ));
    }
    if markers.is_empty() {
        return Err(format!(
            "custom rule '{spec}': needs at least one marker file"
        ));
    }
    let exts: Vec<&str> = markers.iter().filter_map(|m| m.strip_prefix('*')).collect();
    let marker = if exts.len() == markers.len() {
        if exts
            .iter()
            .any(|e| !e.starts_with('.') || e.len() < 2 || e.contains('/'))
        {
            return Err(format!("custom rule '{spec}': extensions look like *.ext"));
        }
        Marker::Ext(Box::leak(
            exts.into_iter()
                .map(leak)
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        ))
    } else if exts.is_empty() {
        if markers
            .iter()
            .any(|m| m.contains('/') || m.contains('*') || *m == "." || *m == "..")
        {
            return Err(format!("custom rule '{spec}': invalid marker file name"));
        }
        Marker::Files(Box::leak(
            markers
                .into_iter()
                .map(leak)
                .collect::<Vec<_>>()
                .into_boxed_slice(),
        ))
    } else {
        return Err(format!(
            "custom rule '{spec}': use either file names or *.ext markers, not both"
        ));
    };
    Ok(Box::leak(Box::new(Rule {
        name: name_match,
        category: CUSTOM,
        marker,
        aggressive: false,
        description: leak(description),
    })))
}

pub fn categories() -> Vec<&'static str> {
    let mut cats: Vec<&'static str> = Vec::new();
    for r in RULES {
        if !cats.contains(&r.category) {
            cats.push(r.category);
        }
    }
    cats
}

/// Human-readable summary of a category, for UIs.
pub fn category_title(category: &str) -> &'static str {
    match category {
        "node" => "Node.js / JavaScript",
        "rust" => "Rust",
        "java" => "Java / Scala",
        "flutter" => "Flutter / Dart",
        "gradle" => "Gradle / Android",
        "cocoapods" => "CocoaPods",
        "xcode" => "Xcode",
        "swift" => "Swift Package Manager",
        "python" => "Python",
        "dotnet" => ".NET",
        "cmake" => "C / C++ (CMake)",
        "elixir" => "Elixir",
        "haskell" => "Haskell",
        "zig" => "Zig",
        "unity" => "Unity",
        "terraform" => "Terraform",
        "global" => "Global caches",
        CUSTOM => "Custom rules",
        _ => "Other",
    }
}

pub fn marker_description(m: Marker) -> String {
    match m {
        Marker::Always => "anywhere".into(),
        Marker::Files(f) => format!("next to {}", f.join(" | ")),
        Marker::Ext(e) => format!("next to *{}", e.join(" | *")),
        Marker::ParentNamed(n) => format!("inside {}/", n.join(" | ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn parses_custom_rules() {
        let r = parse_custom("vendor:composer.json:PHP vendor").unwrap();
        assert_eq!(r.category, CUSTOM);
        assert_eq!(r.display_name(), "vendor");
        assert_eq!(r.description, "PHP vendor");
        assert_eq!(marker_description(r.marker), "next to composer.json");

        let p = parse_custom("bazel-*:WORKSPACE,MODULE.bazel").unwrap();
        assert_eq!(p.display_name(), "bazel-*");
        assert_eq!(p.description, "custom rule");

        let e = parse_custom("Intermediate:*.uproject").unwrap();
        assert_eq!(marker_description(e.marker), "next to *.uproject");

        for bad in [
            "", "x", "x:", "../x:a", "a/b:c", ".git:x", "*:x", "x:*", "x:a,*.b", "x:*foo", "x:a/b",
        ] {
            assert!(parse_custom(bad).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn custom_rule_needs_its_marker() {
        let root = std::env::temp_dir().join(format!("cleaner-rules-{}", std::process::id()));
        fs::create_dir_all(root.join("php/vendor")).unwrap();
        fs::create_dir_all(root.join("notes/vendor")).unwrap();
        fs::write(root.join("php/composer.json"), "{}").unwrap();
        let r = parse_custom("vendor:composer.json").unwrap();
        assert!(match_existing(&root.join("php/vendor"), &[r]).is_some());
        assert!(match_existing(&root.join("notes/vendor"), &[r]).is_none());
        fs::remove_dir_all(&root).unwrap();
    }
}
