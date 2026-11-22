APP_NAME := Cleaner
CASK := cleaner
EXEC := Cleaner
VERSION := $(shell sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -1)
APP := build/$(APP_NAME).app
ZIP := build/$(APP_NAME)-$(VERSION)-macos.zip
TAP := ../homebrew-tap
LLM_URL ?= http://127.0.0.1:9694/v1/chat/completions
LLM_MODEL ?= local

.PHONY: run install deploy

run:
	@pkill -x $(EXEC) || true
	cargo build --bin cleaner-engine
	cd app && swift run Cleaner

install:
	scripts/bundle.sh
	@pkill -x $(EXEC) || true
	rm -rf /Applications/$(APP_NAME).app
	ditto $(APP) /Applications/$(APP_NAME).app
	open /Applications/$(APP_NAME).app

deploy:
	@! git ls-remote --exit-code --tags origin "refs/tags/v$(VERSION)" >/dev/null 2>&1 || { echo "v$(VERSION) exists. Bump the version."; exit 1; }
	scripts/bundle.sh
	git checkout main
	git add -A
	@MSG=$$(git diff --cached | python3 -c 'import json,sys,urllib.request; diff=sys.stdin.read()[:12000]; req=urllib.request.Request("$(LLM_URL)", data=json.dumps({"model":"$(LLM_MODEL)","messages":[{"role":"system","content":"Generate one concise conventional commit message for the git diff. Output ONLY the commit message, no quotes, no markdown, no explanation."},{"role":"user","content":diff}],"temperature":0.2}).encode(), headers={"Content-Type":"application/json"}); print(json.loads(urllib.request.urlopen(req, timeout=60).read())["choices"][0]["message"]["content"].strip())' 2>/dev/null); \
	git commit -m "$${MSG:-chore: release v$(VERSION)}" || true
	git push origin main
	gh release create v$(VERSION) $(ZIP) --title "$(APP_NAME) $(VERSION)" --generate-notes
	cd $(TAP) && git pull -q && scripts/release.sh $(CASK) $(VERSION) && git add -A && git commit -m "$(CASK) $(VERSION)" && git push origin main
