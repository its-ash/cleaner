use clap::Parser;
use cleaner::delete::{self, Method};
use cleaner::{global, project, rules, scan, size};
use console::style;
use dialoguer::{Confirm, MultiSelect, theme::ColorfulTheme};
use rayon::prelude::*;
use std::collections::{BTreeMap, HashSet};
use std::io::{self, IsTerminal};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::{env, fs};

/// Find and delete build artifacts, dependency folders and caches:
/// node_modules, Rust/Maven target, Flutter build & .dart_tool, Gradle/Android build,
/// CocoaPods, Xcode DerivedData, Python caches, .NET bin/obj, CMake builds and more.
///
/// A folder is only deleted when its parent proves the project type
/// (e.g. `target/` next to Cargo.toml, `build/` next to pubspec.yaml or build.gradle).
#[derive(Parser)]
#[command(name = "cleaner", version)]
struct Cli {
    /// Directories to scan [default: current directory]
    paths: Vec<PathBuf>,

    /// Only list what would be deleted
    #[arg(short = 'n', long)]
    dry_run: bool,

    /// Delete without asking for confirmation
    #[arg(short, long, conflicts_with = "interactive")]
    yes: bool,

    /// Pick which folders to delete from a checklist
    #[arg(short, long)]
    interactive: bool,

    /// Also match dist/, out/, coverage/, virtualenvs, Unity Library, .terraform, CMake build/
    #[arg(short, long)]
    aggressive: bool,

    /// Also clean machine-wide caches (Xcode DerivedData, Gradle, npm, pub, cargo, CocoaPods, ...)
    #[arg(short, long)]
    global: bool,

    /// Only these categories (comma separated, e.g. --only node,rust)
    #[arg(long, value_delimiter = ',')]
    only: Vec<String>,

    /// Skip these categories (comma separated, e.g. --skip python)
    #[arg(long, value_delimiter = ',')]
    skip: Vec<String>,

    /// Directory to leave untouched (repeatable)
    #[arg(short = 'x', long)]
    exclude: Vec<PathBuf>,

    /// Also descend into hidden directories (.config, .vscode, ...)
    #[arg(long)]
    hidden: bool,

    /// Move folders to the Trash instead of deleting them permanently
    #[arg(short, long)]
    trash: bool,

    /// Only folders whose project has not been touched for this many days
    #[arg(long, value_name = "DAYS")]
    older_than: Option<u64>,

    /// Only folders at least this big, in MB
    #[arg(long, value_name = "MB")]
    min_size: Option<u64>,

    /// Print every rule and exit
    #[arg(long)]
    list_rules: bool,
}

struct Item {
    path: PathBuf,
    category: &'static str,
    description: &'static str,
    size: u64,
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(code) => code,
        Err(e) => {
            eprintln!("{} {e}", style("error:").red().bold());
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> Result<ExitCode, String> {
    if cli.list_rules {
        print_rules();
        return Ok(ExitCode::SUCCESS);
    }

    let home = cleaner::home_dir();

    // --- rule selection -----------------------------------------------------
    let known = rules::categories();
    let normalize = |v: &[String]| -> Result<Vec<String>, String> {
        v.iter()
            .map(|c| c.trim().to_lowercase())
            .filter(|c| !c.is_empty())
            .map(|c| {
                if known.contains(&c.as_str()) {
                    Ok(c)
                } else {
                    Err(format!(
                        "unknown category '{c}'. Known: {}",
                        known.join(", ")
                    ))
                }
            })
            .collect()
    };
    let only = normalize(&cli.only)?;
    let skip = normalize(&cli.skip)?;
    let active: Vec<&'static rules::Rule> = rules::RULES
        .iter()
        .filter(|r| cli.aggressive || !r.aggressive)
        .filter(|r| only.is_empty() || only.iter().any(|c| c == r.category))
        .filter(|r| !skip.iter().any(|c| c == r.category))
        .collect();

    // --- roots & excludes ---------------------------------------------------
    let roots: Vec<PathBuf> = if cli.paths.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        cli.paths.clone()
    };
    let roots: Vec<PathBuf> = roots
        .iter()
        .map(|p| fs::canonicalize(p).map_err(|e| format!("{}: {e}", p.display())))
        .collect::<Result<_, _>>()?;

    // System and app-data locations are never descended into.
    let mut excludes = cleaner::default_excludes(home.as_deref());
    excludes.extend(cli.exclude.iter().filter_map(|p| fs::canonicalize(p).ok()));

    let opts = scan::ScanOptions {
        rules: active,
        hidden: cli.hidden,
        excludes,
    };

    // --- scan ---------------------------------------------------------------
    eprintln!(
        "{} {}",
        style("Scanning").cyan().bold(),
        roots
            .iter()
            .map(|r| pretty(r, &home))
            .collect::<Vec<_>>()
            .join(", ")
    );

    let mut seen_paths = HashSet::new();
    let mut found: Vec<(PathBuf, &'static str, &'static str)> = Vec::new();
    for root in &roots {
        for (path, rule) in scan::scan(root, &opts) {
            if seen_paths.insert(path.clone()) {
                found.push((path, rule.category, rule.description));
            }
        }
    }
    if cli.global {
        match &home {
            Some(h) => {
                for (label, path) in global::caches(h) {
                    if seen_paths.insert(path.clone()) {
                        found.push((path, "global", label));
                    }
                }
            }
            None => eprintln!(
                "{} $HOME not set, skipping --global",
                style("warning:").yellow()
            ),
        }
    }
    // Drop entries nested inside other entries (overlapping roots).
    let mut deduped = scan::dedupe(found.into_iter().map(|(p, c, d)| (p, (c, d))).collect());
    if let Some(days) = cli.older_than {
        deduped.retain(|(p, _)| {
            project::last_modified(p).is_none_or(|t| project::age_days(t) >= days)
        });
    }

    eprintln!(
        "{} {} folders",
        style("Measuring").cyan().bold(),
        deduped.len()
    );
    let seen = size::Seen::default();
    let mut items: Vec<Item> = deduped
        .into_par_iter()
        .map(|(path, (category, description))| {
            let size = size::dir_size(&path, &seen);
            Item {
                path,
                category,
                description,
                size,
            }
        })
        .collect();
    if let Some(mb) = cli.min_size {
        items.retain(|i| i.size >= mb * 1024 * 1024);
    }
    items.sort_by_key(|i| std::cmp::Reverse(i.size));

    if items.is_empty() {
        println!("{}", style("Nothing to clean.").green());
        return Ok(ExitCode::SUCCESS);
    }

    print_items(&items, &home);

    if cli.dry_run {
        println!("\n{}", style("Dry run: nothing was deleted.").dim());
        return Ok(ExitCode::SUCCESS);
    }

    // --- choose / confirm ---------------------------------------------------
    let interactive_ok = io::stdin().is_terminal() && io::stderr().is_terminal();
    let selected: Vec<Item> = if cli.interactive {
        if !interactive_ok {
            return Err("--interactive needs a terminal".into());
        }
        let labels: Vec<String> = items
            .iter()
            .map(|i| {
                format!(
                    "{:>10}  {:<9}  {}",
                    size::human(i.size),
                    i.category,
                    pretty(&i.path, &home)
                )
            })
            .collect();
        let picked = MultiSelect::with_theme(&ColorfulTheme::default())
            .with_prompt("Select folders to delete (space toggles, enter confirms)")
            .items(&labels)
            .defaults(&vec![true; labels.len()])
            .interact_opt()
            .map_err(|e| e.to_string())?;
        let Some(picked) = picked else {
            println!("Aborted.");
            return Ok(ExitCode::SUCCESS);
        };
        let picked: HashSet<usize> = picked.into_iter().collect();
        items
            .into_iter()
            .enumerate()
            .filter(|(i, _)| picked.contains(i))
            .map(|(_, it)| it)
            .collect()
    } else {
        items
    };

    if selected.is_empty() {
        println!("Nothing selected.");
        return Ok(ExitCode::SUCCESS);
    }

    let total: u64 = selected.iter().map(|i| i.size).sum();
    if !cli.yes {
        if !interactive_ok {
            return Err(
                "refusing to delete without confirmation in a non-interactive shell; pass --yes"
                    .into(),
            );
        }
        let ok = Confirm::with_theme(&ColorfulTheme::default())
            .with_prompt(format!(
                "{} {} folders ({})?",
                if cli.trash {
                    "Move to Trash"
                } else {
                    "Permanently delete"
                },
                selected.len(),
                size::human(total)
            ))
            .default(false)
            .interact()
            .map_err(|e| e.to_string())?;
        if !ok {
            println!("Aborted.");
            return Ok(ExitCode::SUCCESS);
        }
    }

    // --- delete -------------------------------------------------------------
    let method = if cli.trash {
        Method::Trash
    } else {
        Method::Permanent
    };
    let results: Vec<(&Item, io::Result<()>)> = if cli.trash {
        selected
            .iter()
            .map(|i| (i, delete::delete(&i.path, method)))
            .collect()
    } else {
        selected
            .par_iter()
            .map(|i| (i, delete::delete(&i.path, method)))
            .collect()
    };
    let mut freed = 0;
    let mut failures = 0;
    for (item, res) in &results {
        match res {
            Ok(()) => freed += item.size,
            Err(e) => {
                failures += 1;
                eprintln!(
                    "{} {}: {e}",
                    style("failed").red(),
                    pretty(&item.path, &home)
                );
            }
        }
    }
    println!(
        "\n{} {} folders, {} {}",
        style(if cli.trash { "Trashed" } else { "Deleted" })
            .green()
            .bold(),
        results.len() - failures,
        if cli.trash {
            "empty the Trash to free"
        } else {
            "freed"
        },
        style(size::human(freed)).green().bold()
    );
    Ok(if failures > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}

fn pretty(path: &Path, home: &Option<PathBuf>) -> String {
    cleaner::pretty(path, home.as_deref())
}

fn print_items(items: &[Item], home: &Option<PathBuf>) {
    println!();
    for i in items {
        println!(
            "{:>10}  {:<9}  {}  {}",
            style(size::human(i.size)).yellow(),
            style(i.category).cyan(),
            pretty(&i.path, home),
            style(format!("({})", i.description)).dim()
        );
    }

    let mut by_cat: BTreeMap<&str, (usize, u64)> = BTreeMap::new();
    for i in items {
        let e = by_cat.entry(i.category).or_default();
        e.0 += 1;
        e.1 += i.size;
    }
    println!("\n{}", style("Summary").bold());
    for (cat, (count, bytes)) in &by_cat {
        println!(
            "  {:<10} {:>4} folders  {:>10}",
            cat,
            count,
            size::human(*bytes)
        );
    }
    let total: u64 = items.iter().map(|i| i.size).sum();
    println!(
        "  {:<10} {:>4} folders  {:>10}",
        style("total").bold(),
        items.len(),
        style(size::human(total)).bold().yellow()
    );
}

fn print_rules() {
    let mut current = "";
    for r in rules::RULES {
        if r.category != current {
            current = r.category;
            println!("\n{}", style(current).cyan().bold());
        }
        println!(
            "  {:<16} {:<48} {}{}",
            r.display_name(),
            rules::marker_description(r.marker),
            r.description,
            if r.aggressive {
                style("  [--aggressive]").yellow().to_string()
            } else {
                String::new()
            }
        );
    }
    println!("\n{}  (with --global)", style("global").cyan().bold());
    if let Some(h) = env::var_os("HOME") {
        for (label, path) in global::caches(Path::new(&h)) {
            println!("  {:<30} {}", label, path.display());
        }
    }
}
