#!/usr/bin/env sh
#
# codex-termux — run OpenAI Codex CLI natively on Termux (Android).
# No proot. No containers. No VMs. Official codex binaries.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/rexroze/codex-termux/main/install.sh | sh
#   sh install.sh [--version rust-v0.148.0] [--no-download] [--uninstall] [--help]
#
# Env overrides:
#   CODEX_VERSION                e.g. rust-v0.148.0 or 0.148.0 (default: latest)
#   CODEX_TERMUX_INSTALL_DIR     install dir (default: $HOME/bin)
#   CODEX_TERMUX_SHELL           bash|zsh|fish (default: auto-detect from $SHELL)
#   CODEX_TERMUX_NO_PATH         1 = skip PATH/completion setup entirely
#   CODEX_TERMUX_PROXY_PORT      DNS proxy port (default: 18080)
#
set -eu

CODEX_REPO="openai/codex"
VERSION="${CODEX_VERSION:-latest}"
INSTALL_DIR="${CODEX_TERMUX_INSTALL_DIR:-$HOME/bin}"
PROXY_PORT="${CODEX_TERMUX_PROXY_PORT:-18080}"
NO_DOWNLOAD=0
DO_UNINSTALL=0

ARCH="$(uname -m 2>/dev/null || echo unknown)"
TERMUX_PREFIX="${PREFIX:-}"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;32m[codex-termux]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[codex-termux]\033[0m warning: %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[codex-termux]\033[0m error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
codex-termux installer

Usage:
  sh install.sh                install or upgrade codex (latest release)
  sh install.sh -v rust-v0.148.0  install a specific version
  sh install.sh --no-download  only (re)create the launcher + DNS proxy,
                               keep the existing binary in place (repair mode)
  sh install.sh --uninstall    remove the wrapper, proxy, and binary

Env:
  CODEX_VERSION                version to install (default: latest)
  CODEX_TERMUX_INSTALL_DIR     install directory (default: $HOME/bin)
  CODEX_TERMUX_SHELL           bash|zsh|fish (default: auto-detect from $SHELL)
  CODEX_TERMUX_NO_PATH         1 = don't touch PATH/completion config
  CODEX_TERMUX_PROXY_PORT      DNS proxy port (default: 18080)

Version resolution uses GitHub's releases/latest redirect (no api.github.com
— its unauthenticated rate limit causes 403s on shared mobile IPs). Codex
publishes no checksum file, so the sha256 digest is fetched best-effort and
verification is skipped with a warning when unavailable.
The official codex binary is fully static musl, so it runs on Termux
directly (no glibc bridge). Two things are needed for it to work here:
  1. DNS: Android has no /etc/resolv.conf (its /etc -> /system/etc), so
     codex's DNS lookups fail. The launcher starts a tiny local HTTP proxy
     (Node) that resolves hostnames via Android's own resolver and routes
     codex through it with HTTPS_PROXY.
  2. TLS: the static binary can't find Android's CA store, so the launcher
     sets SSL_CERT_FILE to Termux's CA bundle.
A first-run ~/.codex/config.toml is written with sandbox_mode =
"danger-full-access" (codex's default sandbox can't run on Android) and
check_for_update_on_startup = false (codex update would fetch a non-Termux
build).

Shell setup: a PATH line and tab-completions (codex has bash/zsh/fish
completion generators) are added for your login shell.
EOF
  exit 0
}

check_termux() {
  [ -n "$TERMUX_PREFIX" ] && [ -d "$TERMUX_PREFIX" ] \
    || die "Termux not detected. This installer only runs on Termux (Android)."
  command -v pkg >/dev/null 2>&1 \
    || die "Termux package manager (pkg) not found in PATH."
}

check_arch() {
  case "$ARCH" in
    aarch64|arm64) BIN_NAME="codex-aarch64-unknown-linux-musl.tar.gz" ;;
    *)
      die "unsupported architecture: $ARCH. Only aarch64 (ARM64) is supported; \
codex ships no other Android-compatible build."
      ;;
  esac
}

# The DNS proxy is a Node script. Node is also what most users have for the
# npm install path. Install it if missing.
ensure_node() {
  command -v node >/dev/null 2>&1 \
    || { info "installing nodejs (required for the DNS proxy)..."; pkg install -y nodejs \
           || die "failed to install nodejs (run 'pkg install -y nodejs' manually)"; }
  command -v node >/dev/null 2>&1 || die "node not found after install"
}

resolve_release() {
  if [ "$VERSION" = "latest" ]; then
    # Resolve the latest tag via the releases/latest redirect. This is a
    # plain github.com web endpoint with no rate limit — api.github.com's
    # unauthenticated quota (60 req/h per IP) is routinely exhausted on
    # shared mobile IPs (CGNAT), which made installs fail with 403.
    local url
    url="$(curl -fsSL --head -o /dev/null -w '%{url_effective}' \
      "https://github.com/$CODEX_REPO/releases/latest")" \
      || die "could not resolve latest codex version (network error)"
    VERSION="${url##*/}"
  fi
  case "$VERSION" in
    rust-v*|v*) : ;;
    *) die "could not resolve version from release redirect" ;;
  esac
  info "codex version: $VERSION"
}

download_binary() {
  local tmp url
  tmp="$(mktemp -d "${TMPDIR:-$TERMUX_PREFIX/tmp}/codex-termux.XXXXXX")"
  trap '[ -n "${tmp:-}" ] && rm -rf "$tmp"' EXIT INT TERM
  url="https://github.com/$CODEX_REPO/releases/download/$VERSION/$BIN_NAME"
  info "downloading $url ..."
  curl -fsSL -o "$tmp/$BIN_NAME" "$url" || die "download failed: $url"
  verify_checksum "$tmp/$BIN_NAME"
  tar -xzf "$tmp/$BIN_NAME" -C "$tmp" || die "extract failed (corrupt download?)"
  # The archive holds a single file named after the asset (minus .tar.gz).
  # Check the fixed name instead of find/glob — a glob like 'codex*' also
  # matches the tarball itself and would install gzip bytes (magic 1F8B).
  local extracted="$tmp/${BIN_NAME%.tar.gz}"
  [ -f "$extracted" ] || die "archive did not contain the codex binary"
  mv "$extracted" "$INSTALL_DIR/codex-runtime/codex"
  chmod 755 "$INSTALL_DIR/codex-runtime/codex"
  rm -f "$tmp/$BIN_NAME"
}

# Best-effort integrity check. Codex publishes no SHASUMS256.txt; GitHub's
# per-asset sha256 digest is only available via api.github.com, whose
# unauthenticated quota (60 req/h per IP) is often exhausted on shared
# mobile IPs — so failing to fetch it is non-fatal (warn, don't die). The
# download itself always comes from github.com over HTTPS.
verify_checksum() {  # $1 = tarball path
  local hex
  DIGEST="$(curl -fsSL "https://api.github.com/repos/$CODEX_REPO/releases/tags/$VERSION" 2>/dev/null \
    | awk -v n="$BIN_NAME" '
      /"name":/ { gsub(/[",]/, ""); f=($2==n) }
      f && /"digest":/ { gsub(/[",]/, ""); print $2; exit }')" || DIGEST=""
  [ -n "$DIGEST" ] || { warn "could not fetch a published checksum (API rate limit?) — skipping verification"; return 0; }
  hex="${DIGEST#sha256:}"
  case "$hex" in
    ""|*[!0-9a-fA-F]*) warn "unexpected digest format ($DIGEST); skipping checksum check"; return 0 ;;
  esac
  printf '%s  %s\n' "$hex" "$1" | sha256sum -c - >/dev/null 2>&1 \
    || die "sha256 checksum mismatch — download corrupt or tampered; retry"
  info "sha256 checksum verified"
}

write_proxy() {
  local proxy_src="$ROOT_DIR/scripts/codex-proxy.js"
  local proxy_dst="$INSTALL_DIR/codex-runtime/codex-proxy.js"
  mkdir -p "$(dirname "$proxy_dst")"
  if [ -f "$proxy_src" ]; then
    cp "$proxy_src" "$proxy_dst"
  else
    # Installed from raw URL (not a git checkout) — fetch the proxy script
    # from the repo.
    local url="https://raw.githubusercontent.com/rexroze/codex-termux/main/scripts/codex-proxy.js"
    curl -fsSL "$url" -o "$proxy_dst" || die "could not fetch $url"
  fi
  chmod 644 "$proxy_dst"
}

# The launcher. Starts the DNS proxy (if not already listening), exports the
# proxy + CA env vars codex needs, then execs the real binary. The binary
# lives in a subdir named `codex` so the kernel process name stays "codex"
# — agent runtimes like herdr identify agents by process name.
write_wrapper() {
  local wrapper="$INSTALL_DIR/codex"
  local runtime_dir="$INSTALL_DIR/codex-runtime"
  mkdir -p "$runtime_dir"
  cat > "$wrapper" <<EOF
#!/bin/sh
# codex-termux launcher — DNS proxy + TLS for the official static-musl binary.
RUNTIME="$runtime_dir"
PORT="${CODEX_TERMUX_PROXY_PORT:-$PROXY_PORT}"
PIDFILE="\$RUNTIME/codex-proxy.pid"
LOGFILE="\$RUNTIME/codex-proxy.log"

# POSIX-safe port probe (no /dev/tcp — dash doesn't have it); node is
# guaranteed present because the proxy itself is node.
proxy_up() {
  node -e 'var s=require("net").connect(process.argv[1],"127.0.0.1");s.on("connect",function(){s.end();process.exit(0)});s.on("error",function(){process.exit(1)})' "\$PORT" >/dev/null 2>&1
}

if ! proxy_up; then
  if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    : # proxy process exists but port not up yet — wait below
  else
    setsid node "\$RUNTIME/codex-proxy.js" "\$PORT" >"\$LOGFILE" 2>&1 &
    echo \$! > "\$PIDFILE"
  fi
  i=0
  while [ \$i -lt 30 ]; do
    proxy_up && break
    i=\$((i + 1)); sleep 0.2
  done
  proxy_up || { echo "codex-termux: DNS proxy failed to start (see \$LOGFILE)" >&2; exit 1; }
fi

export HTTPS_PROXY="http://127.0.0.1:\$PORT"
export HTTP_PROXY="http://127.0.0.1:\$PORT"
export SSL_CERT_FILE="\$PREFIX/etc/tls/cert.pem"
exec "\$RUNTIME/codex" "\$@"
EOF
  chmod 755 "$wrapper"
}

# First-run config: codex's default sandbox (bubblewrap) can't run on
# Android, and its auto-updater would fetch a non-Termux build. Write these
# defaults only if the user has no config yet.
write_config() {
  local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
  [ -f "$cfg" ] && return 0
  mkdir -p "$(dirname "$cfg")"
  cat > "$cfg" <<EOF
# Generated by codex-termux. See https://github.com/rexroze/codex-termux
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false
EOF
  info "wrote first-run config $cfg (sandbox + update defaults)"
}

detect_shell() {
  SHELL_NAME="${CODEX_TERMUX_SHELL:-}"
  if [ -z "$SHELL_NAME" ]; then
    case "${SHELL:-}" in
      */fish) SHELL_NAME=fish ;;
      */zsh)  SHELL_NAME=zsh ;;
      */bash) SHELL_NAME=bash ;;
      *)
        warn "could not detect a supported shell (SHELL=${SHELL:-unset})."
        warn "re-run with CODEX_TERMUX_SHELL=bash|zsh|fish, or add $INSTALL_DIR to PATH manually."
        ;;
    esac
  fi
}

add_path_line() {  # $1 = rc file, $2 = display name
  local rc="$1"
  mkdir -p "$(dirname "$rc")"
  [ -f "$rc" ] || touch "$rc"
  if ! grep -qF "PATH=\"$INSTALL_DIR:" "$rc"; then
    printf '\n# codex-termux\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$rc"
    info "added $INSTALL_DIR to PATH in $2 ($rc)"
  fi
}

add_path_fish() {
  local rc="$HOME/.config/fish/config.fish"
  mkdir -p "$(dirname "$rc")"
  [ -f "$rc" ] || touch "$rc"
  if ! grep -qF "$INSTALL_DIR" "$rc"; then
    printf '\n# codex-termux\nfish_add_path %s\n' "$INSTALL_DIR" >> "$rc"
    info "added $INSTALL_DIR to fish PATH ($rc)"
  fi
}

completions() {  # $1 = shell
  local out
  case "$1" in
    bash) out="$TERMUX_PREFIX/etc/bash_completion.d/codex" ;;
    zsh)  out="$HOME/.zsh/completions/_codex" ;;
    fish) out="$HOME/.config/fish/completions/codex.fish" ;;
    *) return 0 ;;
  esac
  mkdir -p "$(dirname "$out")"
  if "$INSTALL_DIR/codex" completion "$1" > "$out" 2>/dev/null && [ -s "$out" ]; then
    info "installed $1 completions ($out)"
  else
    rm -f "$out"
    warn "could not generate $1 completions"
  fi
  if [ "$1" = "zsh" ] && [ -f "$out" ]; then
    local rc="$HOME/.zshrc"
    mkdir -p "$(dirname "$rc")"; [ -f "$rc" ] || touch "$rc"
    if ! grep -qF "codex-termux (zsh completions)" "$rc"; then
      printf '\n# codex-termux (zsh completions)\nfpath=(~/.zsh/completions $fpath)\nautoload -Uz compinit && compinit\n' >> "$rc"
    fi
  fi
}

setup_shell() {
  [ "${CODEX_TERMUX_NO_PATH:-0}" = "1" ] && return 0
  detect_shell
  case "$SHELL_NAME" in
    bash) add_path_line "$HOME/.bashrc" "~/.bashrc"; completions bash ;;
    zsh)  add_path_line "$HOME/.zshrc" "~/.zshrc";   completions zsh ;;
    fish) add_path_fish;                              completions fish ;;
  esac
}

do_uninstall() {
  rm -f "$INSTALL_DIR/codex" \
        "$TERMUX_PREFIX/etc/bash_completion.d/codex" \
        "$HOME/.zsh/completions/_codex" \
        "$HOME/.config/fish/completions/codex.fish"
  rm -rf "$INSTALL_DIR/codex-runtime"
  info "removed codex launcher, DNS proxy, and binary"
  info "PATH/completion lines left in shell configs (remove manually if desired);"
  info "~/.codex session data and config kept (remove manually if desired)"
  exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)        usage ;;
      --uninstall)      DO_UNINSTALL=1 ;;
      --no-download)    NO_DOWNLOAD=1 ;;
      -v|--version)     shift; [ "$#" -gt 0 ] || die "--version requires an argument, e.g. -v rust-v0.148.0"; VERSION="$1" ;;
      -v=*|--version=*) VERSION="${1#*=}" ;;
      -v*)              VERSION="${1#-v}" ;;
      *)                die "unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
}

parse_args "$@"
check_termux
check_arch
[ "$DO_UNINSTALL" = "1" ] && do_uninstall

mkdir -p "$INSTALL_DIR/codex-runtime"

if [ "$NO_DOWNLOAD" = "1" ]; then
  [ -x "$INSTALL_DIR/codex-runtime/codex" ] || die "--no-download but no binary in $INSTALL_DIR/codex-runtime"
else
  ensure_node
  resolve_release
  download_binary
fi

write_proxy
write_wrapper
write_config
setup_shell

info "installed:"
info "  binary $INSTALL_DIR/codex-runtime/codex ($(du -h "$INSTALL_DIR/codex-runtime/codex" 2>/dev/null | cut -f1)) — official, unmodified"
info "  launcher $INSTALL_DIR/codex (starts DNS proxy on 127.0.0.1:$PROXY_PORT on demand)"
case "${SHELL_NAME:-}" in
  bash) info "shell refresh:  source ~/.bashrc   (or just open a new Termux session)" ;;
  zsh)  info "shell refresh:  source ~/.zshrc   (or just open a new Termux session)" ;;
  fish) info "shell refresh:  exec fish   (or just open a new Termux session)" ;;
  *)    info "shell refresh:  open a new Termux session" ;;
esac
info "then run 'codex login' (or set OPENAI_API_KEY) and start coding."
"$INSTALL_DIR/codex" --version || warn "launcher works but --version check failed"