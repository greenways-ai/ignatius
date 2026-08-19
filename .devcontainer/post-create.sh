#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "error: run from an Ignatius checkout" >&2; exit 1; }

HARA_REVISION="d305875e3bfe3d8fc4f8a1462053e4ca901aaa74"
FOUNDATION_REVISION="baa75aabd6a879753d7d5cb07271b1448271e7cb"
HARA_CHECKOUT="$repo_root/.local/hara.lang"
FOUNDATION_CHECKOUT="$repo_root/db/checkouts/foundation"

fail() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }

persist_local_bin() {
  local line='export PATH="$HOME/.local/bin:$PATH"'
  mkdir -p "$HOME/.local/bin"
  touch "$HOME/.bashrc"
  grep -Fqx "$line" "$HOME/.bashrc" || printf '\n%s\n' "$line" >> "$HOME/.bashrc"
  export PATH="$HOME/.local/bin:$PATH"
}

select_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    source "$NVM_DIR/nvm.sh"
    nvm install 24
    nvm use 24
  fi
  need node; need npm
  [[ "$(node -p 'process.versions.node.split(".")[0]')" == 24 ]] \
    || fail "Node 24 is required; found $(node --version)"
}

select_java() {
  local candidate="/usr/lib/jvm/java-17-openjdk-amd64"
  if [[ -x "$candidate/bin/java" ]]; then
    export JAVA_HOME="$candidate"
    export PATH="$JAVA_HOME/bin:$PATH"
  fi
  need java
  java -version 2>&1 | head -n 1 | grep -Eq '(version "17[.]|openjdk 17[.])' \
    || fail "JDK 17 is required"
}

ensure_rust() {
  need rustup
  rustup toolchain install 1.88.0 --profile minimal
  need cargo
}

ensure_lein() {
  if ! command -v lein >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/technomancy/leiningen/2.11.2/bin/lein \
      -o "$HOME/.local/bin/lein"
    chmod 0755 "$HOME/.local/bin/lein"
  fi
  lein version >/dev/null
}

preflight_checkout() {
  local checkout="$1" revision="$2"
  [[ -e "$checkout" ]] || return
  [[ -d "$checkout/.git" ]] || fail "$checkout exists but is not a Git checkout"
  [[ -z "$(git -C "$checkout" status --porcelain --untracked-files=all)" ]] \
    || fail "dependency checkout is dirty: $checkout"
  local actual
  actual="$(git -C "$checkout" rev-parse HEAD)"
  [[ "$actual" == "$revision" ]] \
    || fail "dependency revision mismatch at $checkout (expected $revision, found $actual); refusing to run the reset-capable repository helper"
}

print_version() {
  local label="$1"; shift
  printf '%-14s ' "$label:"
  "$@" --version 2>&1 | head -n 1 || true
}

persist_local_bin
select_node
select_java
ensure_rust
ensure_lein
need git; need python3; need psql

preflight_checkout "$HARA_CHECKOUT" "$HARA_REVISION"
preflight_checkout "$FOUNDATION_CHECKOUT" "$FOUNDATION_REVISION"
bash "$repo_root/scripts/setup-dependencies"

[[ "$(git -C "$HARA_CHECKOUT" rev-parse HEAD)" == "$HARA_REVISION" ]] \
  || fail "scripts/setup-dependencies produced the wrong Hara revision"
[[ "$(git -C "$FOUNDATION_CHECKOUT" rev-parse HEAD)" == "$FOUNDATION_REVISION" ]] \
  || fail "scripts/setup-dependencies produced the wrong Foundation revision"

hara_manifest="$HARA_CHECKOUT/core/rust/Cargo.toml"
[[ -f "$hara_manifest" ]] || fail "pinned Hara manifest is missing"
cargo +1.88.0 fetch --locked --manifest-path "$hara_manifest"
cargo +1.88.0 build --locked --release --manifest-path "$hara_manifest" --bin hara --bin hara-test
install -m 0755 "$HARA_CHECKOUT/core/rust/target/release/hara" "$HOME/.local/bin/hara"
install -m 0755 "$HARA_CHECKOUT/core/rust/target/release/hara-test" "$HOME/.local/bin/hara-test"

while IFS= read -r -d '' project; do
  (cd "$(dirname "$project")" && lein deps)
done < <(find "$repo_root" \
  -path '*/.git' -prune -o \
  -path '*/target' -prune -o \
  -name project.clj -print0)

cargo +1.88.0 fetch --locked --manifest-path "$repo_root/extensions/sha/rust/Cargo.toml"
npm ci --prefix "$repo_root/site"

[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]] \
  || fail "setup changed the Ignatius working tree"

printf '\nIgnatius development environment ready.\n'
print_version "Java" java
print_version "Leiningen" lein
print_version "Node" node
print_version "npm" npm
print_version "Rust" rustc +1.88.0
print_version "Cargo" cargo +1.88.0
print_version "PostgreSQL" psql
print_version "Hara" hara
print_version "hara-test" hara-test
printf 'Hara revision:       %s\n' "$(git -C "$HARA_CHECKOUT" rev-parse HEAD)"
printf 'Foundation revision: %s\n' "$(git -C "$FOUNDATION_CHECKOUT" rev-parse HEAD)"
cat <<'CHECKS'

Available checks (dependencies are prepared for offline execution):
  bash scripts/check-architecture-boundaries
  bash scripts/check-ledger-hal-parity
  bash scripts/build-chain-release --help
  cargo +1.88.0 test --locked --manifest-path extensions/sha/rust/Cargo.toml
  npm run build --prefix site

Run repository HAL checks/tests and Lein generators with the documented project
commands, then verify that `git status --short` remains empty.

Optional Docker integration (only when a daemon is available):
  docker info
CHECKS
