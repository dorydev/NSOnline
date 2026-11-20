# NSOnline build tooling (macOS / Linux; on Windows use Git Bash or MSYS2 make,
# or WSL for the Linux packages). Run `make help` for the list of targets.
#
# Nothing here talks to GitHub: releases are uploaded by hand (see
# scripts/release.sh and CONTRIBUTING.md).

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

ROOT      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP_DIR   := $(ROOT)/app
DIST      := $(ROOT)/dist
BUILD_DIR := $(ROOT)/build/backend

# Version: pubspec.yaml is the source of truth ("version: 0.1.0+2" -> 0.1.0).
VERSION ?= $(shell sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' $(APP_DIR)/pubspec.yaml)
ifeq ($(strip $(VERSION)),)
$(error could not read the version from app/pubspec.yaml)
endif

# Flutter executable name (BINARY_NAME / PRODUCT_NAME in the runners).
APP_NAME := nsonline

# .env used by the secrets generator (same lookup as backend/internal/secrets/gen).
ENV_FILE := $(if $(NSONLINE_ENV_FILE),$(NSONLINE_ENV_FILE),$(ROOT)/.env)

GO      ?= go
FLUTTER ?= flutter
DART    ?= dart
GOFLAGS_BUILD := -trimpath
LDFLAGS := -s -w -X nsonline/internal/version.Version=$(VERSION)

# ---- host detection --------------------------------------------------------
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  HOST_OS := macos
else ifeq ($(UNAME_S),Linux)
  HOST_OS := linux
else ifneq ($(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)),)
  HOST_OS := windows
else
  HOST_OS := unknown
endif

HOST_GOOS   := $(shell $(GO) env GOOS 2>/dev/null)
HOST_GOARCH := $(shell $(GO) env GOARCH 2>/dev/null)
EXE         := $(if $(filter windows,$(HOST_GOOS)),.exe,)
BACKEND_BIN := $(BUILD_DIR)/$(HOST_GOOS)-$(HOST_GOARCH)/nsonline$(EXE)
BACKEND_UNIVERSAL := $(BUILD_DIR)/darwin-universal/nsonline

# Flutter release outputs (the backend goes next to the executable).
MACOS_APP     := $(APP_DIR)/build/macos/Build/Products/Release/$(APP_NAME).app
MACOS_EXE_DIR := $(MACOS_APP)/Contents/MacOS
WINDOWS_DIR   := $(APP_DIR)/build/windows/x64/runner/Release
LINUX_BUNDLE  := $(APP_DIR)/build/linux/x64/release/bundle

ifeq ($(HOST_OS),macos)
  APP_OUT_DIR := $(MACOS_EXE_DIR)
  APP_BACKEND := $(BACKEND_UNIVERSAL)
else ifeq ($(HOST_OS),windows)
  APP_OUT_DIR := $(WINDOWS_DIR)
  APP_BACKEND := $(BACKEND_BIN)
else
  APP_OUT_DIR := $(LINUX_BUNDLE)
  APP_BACKEND := $(BACKEND_BIN)
endif

# Release artifact names.
MAC_ZIP  := $(DIST)/NSOnline-$(VERSION)-macos-universal.zip
MAC_DMG  := $(DIST)/NSOnline-$(VERSION)-macos-universal.dmg
WIN_EXE  := $(DIST)/NSOnline-$(VERSION)-windows-x64-setup.exe
LIN_AI   := $(DIST)/NSOnline-$(VERSION)-linux-x86_64.AppImage
LIN_DEB  := $(DIST)/NSOnline-$(VERSION)-linux-amd64.deb

# `make package-x SKIP_BUILD=1` packages the existing build without rebuilding.
PKG_DEPS := $(if $(SKIP_BUILD),,build)

.PHONY: help check-env secrets i18n backend backend-universal app build test \
        package-macos package-windows package-linux checksums clean version

help: ## Show this help
	@echo "NSOnline $(VERSION) - host: $(HOST_OS) ($(HOST_GOOS)/$(HOST_GOARCH))"
	@echo
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*## "}; {printf "  %-18s %s\n", $$1, $$2}'
	@echo
	@echo "Variables: VERSION=$(VERSION)  SKIP_BUILD=1 (package without rebuilding)"
	@echo "           NSONLINE_ENV_FILE=<path> (use another .env)  NSONLINE_UNSIGNED=1 (macOS: skip signing)"

version: ## Print the version read from app/pubspec.yaml
	@echo $(VERSION)

check-env: ## Fail if the .env file used for embedded secrets is missing
	@if [ ! -f "$(ENV_FILE)" ]; then \
	  echo "error: $(ENV_FILE) not found." >&2; \
	  echo "       Run: cp .env.example .env   and fill in your own Discord / nxapi-auth values" >&2; \
	  echo "       (see CONTRIBUTING.md, section 'Secrets')." >&2; \
	  exit 1; \
	fi
	@echo "ok: using $(ENV_FILE) (values are not printed)"

secrets: check-env ## Generate backend/internal/secrets/secrets_gen.go from .env (obfuscated)
	cd $(ROOT) && $(GO) generate ./backend/internal/secrets

i18n: ## Check shared/i18n/*.json and regenerate app/lib/i18n/strings.g.dart
	cd $(ROOT) && $(GO) run ./shared/i18n/cmd/i18ncheck shared/i18n
	cd $(APP_DIR) && $(DART) run tool/gen_i18n.dart

backend: ## Build the nsonline backend for the host OS
	@mkdir -p $(dir $(BACKEND_BIN))
	cd $(ROOT) && $(GO) build $(GOFLAGS_BUILD) -ldflags "$(LDFLAGS)" -o $(BACKEND_BIN) ./backend/cmd/nsonline
	@echo "built $(BACKEND_BIN)"

backend-universal: ## macOS only: universal (amd64 + arm64) backend via lipo
ifneq ($(HOST_OS),macos)
	@echo "error: backend-universal needs macOS (lipo)" >&2; exit 1
else
	@mkdir -p $(BUILD_DIR)/darwin-amd64 $(BUILD_DIR)/darwin-arm64 $(dir $(BACKEND_UNIVERSAL))
	cd $(ROOT) && GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 $(GO) build $(GOFLAGS_BUILD) -ldflags "$(LDFLAGS)" \
	  -o $(BUILD_DIR)/darwin-amd64/nsonline ./backend/cmd/nsonline
	cd $(ROOT) && GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 $(GO) build $(GOFLAGS_BUILD) -ldflags "$(LDFLAGS)" \
	  -o $(BUILD_DIR)/darwin-arm64/nsonline ./backend/cmd/nsonline
	lipo -create -output $(BACKEND_UNIVERSAL) $(BUILD_DIR)/darwin-amd64/nsonline $(BUILD_DIR)/darwin-arm64/nsonline
	lipo -info $(BACKEND_UNIVERSAL)
endif

# On macOS the app embeds the universal backend (the Flutter .app is universal too).
ifeq ($(HOST_OS),macos)
app: i18n backend-universal
else
app: i18n backend
endif
app: ## Flutter release build for the host OS + copy the backend next to the executable
ifeq ($(HOST_OS),unknown)
	@echo "error: unsupported host $(UNAME_S)" >&2; exit 1
endif
	cd $(APP_DIR) && $(FLUTTER) build $(HOST_OS) --release
	@test -d "$(APP_OUT_DIR)" || { echo "error: Flutter output $(APP_OUT_DIR) not found" >&2; exit 1; }
	cp -f $(APP_BACKEND) $(APP_OUT_DIR)/nsonline-core$(EXE)
	chmod 755 $(APP_OUT_DIR)/nsonline-core$(EXE)
ifeq ($(HOST_OS),macos)
	@# Adding a file to Contents/MacOS breaks the bundle seal: re-sign ad hoc so the
	@# local build still launches. Release signing is done by package-macos.
	codesign --force --sign - --options runtime --entitlements $(ROOT)/packaging/macos/entitlements.plist $(APP_OUT_DIR)/nsonline-core
	codesign --force --sign - --entitlements $(ROOT)/packaging/macos/entitlements.plist $(MACOS_APP)
endif
	@echo "app ready in $(APP_OUT_DIR)"

build: check-env secrets backend app ## check-env + secrets + backend + app

test: ## go vet, go test -race, flutter analyze, flutter test
	cd $(ROOT) && $(GO) vet ./backend/... ./shared/...
	cd $(ROOT) && $(GO) test -race ./backend/... ./shared/...
	cd $(APP_DIR) && $(FLUTTER) analyze
	cd $(APP_DIR) && $(FLUTTER) test

package-macos: $(PKG_DEPS) ## Sign + notarize the .app, then build the .zip and .dmg in dist/
ifneq ($(HOST_OS),macos)
	@echo "error: package-macos needs macOS" >&2; exit 1
else
	@mkdir -p $(DIST)
	$(ROOT)/packaging/macos/sign-and-notarize.sh "$(MACOS_APP)" "$(MAC_ZIP)"
	$(ROOT)/packaging/macos/make-dmg.sh "$(MACOS_APP)" "$(MAC_DMG)" "$(VERSION)"
endif

package-windows: $(PKG_DEPS) ## Build the Inno Setup installer in dist/ (needs iscc on PATH)
ifneq ($(HOST_OS),windows)
	@echo "error: package-windows needs Windows (Git Bash/MSYS2) with Inno Setup 6; or run packaging/windows/build.ps1" >&2; exit 1
else
	@mkdir -p $(DIST)
	@command -v iscc >/dev/null || { echo "error: iscc (Inno Setup 6) not on PATH" >&2; exit 1; }
	@# MSYS would rewrite /DAppVersion=... into a path without these.
	MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' iscc \
	  "/DAppVersion=$(VERSION)" \
	  "/DBuildDir=$$(cygpath -w '$(WINDOWS_DIR)')" \
	  "/O$$(cygpath -w '$(DIST)')" \
	  "$$(cygpath -w '$(ROOT)/packaging/windows/nsonline.iss')"
	@test -f "$(WIN_EXE)" && echo "built $(WIN_EXE)"
endif

package-linux: $(PKG_DEPS) ## Build the AppImage and the .deb in dist/
ifneq ($(HOST_OS),linux)
	@echo "error: package-linux needs Linux (or WSL)" >&2; exit 1
else
	@mkdir -p $(DIST)
	$(ROOT)/packaging/linux/build-appimage.sh "$(LINUX_BUNDLE)" "$(LIN_AI)" "$(VERSION)"
	$(ROOT)/packaging/linux/build-deb.sh "$(LINUX_BUNDLE)" "$(LIN_DEB)" "$(VERSION)"
endif

checksums: ## Write dist/SHA256SUMS for the NSOnline-<version>-* artifacts in dist/
	$(ROOT)/scripts/checksums.sh "$(DIST)" "$(VERSION)"

clean: ## Remove dist/, build/backend and the Flutter build (keeps secrets_gen.go)
	rm -rf $(DIST) $(BUILD_DIR)
	cd $(APP_DIR) && $(FLUTTER) clean
