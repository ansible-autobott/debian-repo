# autobott Debian repository — build, sign and publish a static APT repo.
#
# Two ways a package enters the repo:
#   1. Automated: an app's CI commits packages/<app>.json (a signed reference to
#      its release .deb); `hydrate` downloads + verifies it.
#   2. Manual:    `make add DEB=foo.deb` stages a binary into debs/ which you
#      commit directly. Both are merged into the published pool.
#
# Local dry-run of the whole CI publish:  make publish && make serve

# Landing-page config (title, URLs, colour theme) lives in conf/site.conf.
# Colour theme: 'violet' is the built-in default; alternates live in
# conf/themes/<name>.css — run `make themes` to list them. Set it in
# conf/site.conf, or override for a single build: `make publish THEME=teal`.
THEME       ?=
KEY_NAME    ?= autobott APT repository
KEY_EMAIL   ?= contact@andresbott.com

SITE        ?= _site
DIST        ?= dist
FTPCONF     := conf/apt-ftparchive.conf
SCHEMA      := schema/package.schema.json
ARCHES      := $(shell . ./conf/dists.conf 2>/dev/null && echo $$ARCHES)
KEYRING_PUB := autobott-archive-keyring.gpg
KEYRING_ASC := autobott-archive-keyring.asc
KEY_SECRET_ASC := autobott-signing-key.secret.asc

# All GPG operations use a repository-local keyring by default so the private
# key never mixes with the user's personal one. CI overrides GNUPGHOME to a temp
# dir outside the tree. `?=` lets that override win.
GNUPGHOME   ?= $(CURDIR)/.gnupg-repo
export GNUPGHOME

default: help

#==========================================================================================
##@ Repository
#==========================================================================================

.PHONY: publish
publish: validate hydrate build ## full local rebuild (mirrors CI): validate -> hydrate -> build

.PHONY: validate
validate: ## validate packages/*.json against the JSON schema
	@files=$$(find packages -name '*.json' 2>/dev/null); \
	 if [ -z "$$files" ]; then echo "⚠️  no package files to validate"; exit 0; fi; \
	 command -v check-jsonschema >/dev/null 2>&1 || { echo "❌ check-jsonschema not found (pip install check-jsonschema)"; exit 1; }; \
	 check-jsonschema --schemafile $(SCHEMA) $$files && echo "✅ all package files valid"

.PHONY: test
test: ## run schema regression tests (fixtures under tests/)
	@./tests/schema_test.sh

.PHONY: hydrate
hydrate: ## assemble $(SITE)/pool from packages/*.json (download+verify) and debs/
	@./scripts/hydrate.sh "$(SITE)"

.PHONY: build
build: require-key ## generate + GPG-sign the index in $(SITE) from the pool
	@THEME="$(THEME)" ./scripts/gen-index.sh "$(SITE)" "$(FTPCONF)" "$(KEY_EMAIL)"
	@echo ">> tip: 'make serve' to test locally, or commit+push to publish via CI"

.PHONY: add
add: ## stage a local .deb into debs/ for manual, git-committed hosting: make add DEB=path/to.deb
	@[ "$(DEB)" ] || ( echo ">> usage: make add DEB=path/to/pkg.deb"; exit 1 )
	@[ -f "$(DEB)" ] || ( echo "❌ no such file: $(DEB)"; exit 1 )
	@dpkg-deb --info "$(DEB)" >/dev/null 2>&1 || ( echo "❌ not a valid .deb: $(DEB)"; exit 1 )
	@mkdir -p debs
	@cp "$(DEB)" debs/
	@pkg=$$(dpkg-deb -f "$(DEB)" Package); ver=$$(dpkg-deb -f "$(DEB)" Version); arch=$$(dpkg-deb -f "$(DEB)" Architecture); \
	 echo "✅ staged debs/$$(basename "$(DEB)")  ($$pkg $$ver $$arch)"; \
	 echo ">> commit it (git add debs/ && git commit); the push publishes it"

.PHONY: register
register: ## generate a packages/<name>.json locally from built debs: make register NAME=app REPO=owner/app TAG=vX.Y.Z [DIST=dist]
	@[ "$(NAME)" ] && [ "$(REPO)" ] && [ "$(TAG)" ] || ( echo ">> usage: make register NAME=go-deps-view REPO=ansible-autobott/go-deps-view TAG=v1.3.0 [DIST=dist]"; exit 1 )
	@./scripts/register.sh --name "$(NAME)" --dist-dir "$(DIST)" --repo "$(REPO)" --tag "$(TAG)" --out "packages/$(NAME).json"
	@echo ">> commit packages/$(NAME).json to publish (normally the app CI does this via the register action)"

.PHONY: verify
verify: require-key ## sanity-check a built site: every suite's signature valid + pooled debs parse
	@. ./conf/dists.conf; ok=1; \
	 for s in $$DISTS $$(for a in $$ALIASES; do echo $${a%%:*}; done); do \
	   if gpg --verify "$(SITE)/dists/$$s/InRelease" >/dev/null 2>&1; then echo "✅ $$s signature OK"; \
	   else echo "❌ $$s signature failed (run 'make publish'?)"; ok=0; fi; done; \
	 debs=$$(find "$(SITE)/pool" -name '*.deb' 2>/dev/null); \
	 [ -n "$$debs" ] || echo "⚠️  no .deb files in the pool"; \
	 for d in $$debs; do dpkg-deb --info "$$d" >/dev/null 2>&1 || { echo "❌ $$d"; ok=0; }; done; \
	 [ $$ok -eq 1 ]

.PHONY: serve
serve: ## serve the built site at http://localhost:8000 (renders demo content if the repo has no packages)
	@if [ -d "$(SITE)/pool" ] && find "$(SITE)/pool" -name '*.deb' 2>/dev/null | grep -q .; then \
		dir="$(SITE)"; \
	else \
		dir=".cache/preview"; \
		echo "⚠️  no packages in $(SITE) — serving demo preview only (run 'make publish' to build the real site; demo content is never published)"; \
		rm -rf "$$dir"; mkdir -p "$$dir"; \
		DEMO_WHEN_EMPTY=1 THEME="$(THEME)" ./scripts/render-index.sh "$$dir" $(ARCHES); \
	fi; \
	echo ">> serving $$dir at http://localhost:8000 (Ctrl-C to stop)"; \
	cd "$$dir" && python3 -m http.server 8000

.PHONY: themes
themes: ## list the landing-page colour themes (use: make publish THEME=<name>)
	@echo "violet   (built-in default)"
	@for f in conf/themes/*.css; do [ -e "$$f" ] && echo "$$(basename "$$f" .css)"; done

.PHONY: clean
clean: ## remove the built site and caches (keeps packages/ and debs/)
	@rm -rf "$(SITE)" .cache
	@echo "✅ removed $(SITE)/ and .cache/"

#==========================================================================================
##@ Signing
#==========================================================================================

.PHONY: key
key: ## generate the GPG signing key (one-time; refuses to overwrite)
	@mkdir -p -m 700 "$(GNUPGHOME)"
	@if gpg --list-secret-keys "$(KEY_EMAIL)" >/dev/null 2>&1; then \
		echo "⚠️  a signing key for <$(KEY_EMAIL)> already exists in $(GNUPGHOME)"; \
		echo ">> refusing to overwrite. inspect it with 'make key-info'"; \
		exit 1; \
	fi
	@echo ">> generating RSA-4096 signing key '$(KEY_NAME) <$(KEY_EMAIL)>'"
	@echo ">> (no passphrase — required for unattended signing; keep .gnupg-repo/ private)"
	@printf '%s\n' \
		'%no-protection' \
		'Key-Type: RSA' \
		'Key-Length: 4096' \
		'Key-Usage: sign' \
		'Name-Real: $(KEY_NAME)' \
		'Name-Email: $(KEY_EMAIL)' \
		'Expire-Date: 0' \
		'%commit' \
		| gpg --batch --gen-key
	@$(MAKE) --no-print-directory export-key
	@$(MAKE) --no-print-directory backup-key
	@echo "✅ signing key created. run 'make publish' to build a signed repo."

.PHONY: export-key
export-key: require-key ## (re)export the public signing key (binary + armored)
	@gpg --export "$(KEY_EMAIL)" > $(KEYRING_PUB)
	@gpg --export --armor "$(KEY_EMAIL)" > $(KEYRING_ASC)
	@echo "✅ exported $(KEYRING_PUB) (for apt) and $(KEYRING_ASC) (armored)"

.PHONY: backup-key
backup-key: require-key ## export the PRIVATE signing key (armored) for offline/vault backup
	@gpg --export-secret-keys --armor "$(KEY_EMAIL)" > $(KEY_SECRET_ASC)
	@chmod 600 $(KEY_SECRET_ASC)
	@echo "✅ wrote $(KEY_SECRET_ASC) (armored PRIVATE key, git-ignored)"
	@echo "⚠️  move it to your password vault, then shred the local copy: shred -u $(KEY_SECRET_ASC)"

.PHONY: key-info
key-info: require-key ## show the signing key fingerprint and uid
	@gpg --fingerprint "$(KEY_EMAIL)"

.PHONY: require-key
require-key:
	@if [ ! -d "$(GNUPGHOME)" ] || ! gpg --list-secret-keys "$(KEY_EMAIL)" >/dev/null 2>&1; then \
		echo "❌ no signing key found in $(GNUPGHOME)"; \
		echo ">> run 'make key' to generate one (one-time), or set GNUPGHOME/import in CI"; \
		exit 1; \
	fi

#==========================================================================================
#  Help
#==========================================================================================
.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
