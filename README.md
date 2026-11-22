# cleaner

Finds and deletes build output, dependency folders and tool caches across all your projects. It comes as a native macOS app (SwiftUI) and as a fast Rust CLI. Both use the same Rust engine.

It cleans `node_modules`, Rust `target/` (debug and release), Flutter `build/` and `.dart_tool/`, Android/Gradle `build/` and `.gradle/`, CocoaPods `Pods/`, Xcode `DerivedData`, SwiftPM `.build/`, Python caches, .NET `bin/` and `obj/`, CMake `cmake-build-*`, Elixir, Haskell, Zig and more.

With `--global` it also clears machine-wide caches: Xcode DerivedData, iOS DeviceSupport, SwiftUI Previews, SwiftPM and Carthage, Gradle caches and wrapper dists, the Maven repository, the pub cache, npm, Yarn, pnpm, Bun, Deno, node-gyp, Electron, Playwright, Cypress, Cargo registry, CocoaPods, pip, uv, Poetry, Go modules, Composer and Homebrew.

## Mac app

```sh
make run       # run from SwiftPM without bundling (debug)
make install   # build Cleaner.app, copy it to /Applications, open it
make deploy    # release: zip with INSTALL.txt, GitHub release, Homebrew tap
```

Requires macOS 14+, a Rust toolchain and the Xcode command line tools. Bump `version` in `Cargo.toml` before `make deploy`.

What it does:

- **Overview**: shows reclaimable space, free disk space, a chart by category, your biggest projects and the space freed so far.
- **Folder table**: sort by size, age, file count, project or type. Filter by text or by how long a project has been untouched. Tick folders with checkboxes, or select rows and press Space.
- **Smart pre-selection**: folders of projects you changed in the last 7 days (configurable), aggressive matches and global caches start unticked.
- **Projects view**: groups folders by git repository, so you can clean one whole project at once.
- **Trash or delete**: move folders to the Trash so you can put them back with Finder, or delete them permanently.
- **Confirmation**: before anything is removed, a sheet lists what will go and warns about recently used projects and aggressive matches.
- **Right-click menu**: Show in Finder, open the project in Finder or Terminal, copy the path, always ignore this folder or project.
- **History**: every cleanup is recorded with a per-day chart and the full list of paths.
- **Rules browser**: lists every rule with its marker file, with a toggle per category.
- **Settings**: scan locations, exclusions, categories, minimum size, scan on launch, open at login.
- **Other**: menu bar extra, Dock badge with the reclaimable size, notifications when work finishes in the background, drag-and-drop folders onto the window, CSV export, keyboard shortcuts (⌘R scan, ⌘. stop, ⌘⌫ clean, ⇧⌘E export).

### How it fits together

```
Cleaner.app (SwiftUI)  ──spawn──▶  cleaner-engine (Rust)
        ▲                               │
        └──── NDJSON events on stdout ◀─┘
```

`cleaner-engine` is a small JSON front end over the same library the CLI uses:

```sh
cleaner-engine rules                       # catalog of categories, rules, global caches
cleaner-engine scan --global -- ~/Code      # found / measured / progress / done events
echo '["/abs/path/node_modules"]' | cleaner-engine delete [--trash] [--dry-run]
```

The engine never trusts the app. Before each delete it checks the path again: it must be absolute, already canonical, not a symlink, not `/` or your home folder, and it must still match a rule against its parent's current contents (or be a known global cache). Anything else is reported as `failed` and left alone.

## Safety

- A folder is matched only when its parent proves the project type. For example, `target/` must sit next to `Cargo.toml`, `pom.xml` or `build.sbt`. `build/` must sit next to `pubspec.yaml`, `build.gradle` or `*.xcodeproj`. `node_modules` must sit next to `package.json`. A random `build/` folder with your notes in it is never touched.
- It always shows the full list with sizes and asks before deleting. You can preview with `--dry-run` and pick folders with `--interactive`.
- It never follows symlinks and never descends into `.git`, hidden folders (unless you pass `--hidden`), `~/Library` or system directories.
- Folders that are slow to rebuild or ambiguous (`dist/`, `out/`, virtualenvs, Unity `Library/`, `.terraform`) are only matched with `--aggressive`.

## Install

```sh
cargo install --path .
```

## Usage

```sh
cleaner ~/Projects --dry-run         # preview what would be deleted
cleaner ~/Projects                   # list, confirm, delete
cleaner ~/Projects -i                # pick from a checklist
cleaner ~/Projects --only node,rust  # only node_modules and Cargo targets
cleaner ~/Projects --skip python
cleaner ~/Projects -x ~/Projects/active-app   # leave one project alone
cleaner ~ -g                         # projects in ~ plus global caches
cleaner --list-rules                 # show every rule and its marker
cleaner ~/Projects -y                # no prompt (for scripts / cron)
cleaner ~/Projects --trash           # move to the Trash instead of deleting
cleaner ~/Projects --older-than 90   # only projects untouched for 90+ days
cleaner ~/Projects --min-size 100    # ignore folders under 100 MB
```

Categories: `node, rust, java, flutter, gradle, cocoapods, xcode, swift, python, dotnet, cmake, elixir, haskell, zig, unity, terraform`.
