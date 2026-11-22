# Run `cleaner` on the Desktop (or any folder: make DIR=~/Projects).
#
#   make            list everything under ~/Desktop, ask, then delete
#   make preview    list only, delete nothing
#   make pick       choose folders from a checklist
#   make deep       also --aggressive folders and --global caches
#   make yes        delete without asking (careful)
#
# Mac app (SwiftUI front end + Rust engine):
#   make app        build build/Cleaner.app
#   make open-app   build it and open it
#   make dev-app    run the app straight from SwiftPM (debug)
#   make test-all   Rust and Swift tests
#
# Extra flags: make ARGS="--skip python -x ~/Desktop/active-app"

DIR  ?= $(HOME)/Desktop
ARGS ?=

# The binary is copied out of target/ so cleaning this project's own
# target/ folder doesn't remove the tool you are running.
BIN := bin/cleaner
SRC := Cargo.toml $(wildcard src/*.rs)

.DEFAULT_GOAL := run
.PHONY: run preview pick deep yes install test app open-app dev-app test-all

run: $(BIN)
	@$(BIN) "$(DIR)" $(ARGS)

preview: $(BIN)
	@$(BIN) "$(DIR)" --dry-run $(ARGS)

pick: $(BIN)
	@$(BIN) "$(DIR)" --interactive $(ARGS)

deep: $(BIN)
	@$(BIN) "$(DIR)" --aggressive --global $(ARGS)

yes: $(BIN)
	@$(BIN) "$(DIR)" --yes $(ARGS)

$(BIN): $(SRC)
	cargo build --release
	@mkdir -p bin
	cp target/release/cleaner $(BIN)

install:
	cargo install --path .

test:
	cargo test

app:
	@scripts/bundle.sh

open-app: app
	open build/Cleaner.app

dev-app:
	cargo build --bin cleaner-engine
	cd app && swift run Cleaner

test-all:
	cargo test
	cd app && swift test
