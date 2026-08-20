#!/usr/bin/env sh
# codex-termux smoke test — exercises installer + launcher + DNS proxy in an
# isolated HOME. Requires Termux with nodejs and network access (to hit the
# GitHub API for release metadata; skips the actual binary download).
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_HOME="$(mktemp -d "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/codex-test.XXXXXX")"
trap 'rm -rf "$TEST_HOME"' EXIT INT TERM

export HOME="$TEST_HOME"
export CODEX_TERMUX_NO_PATH=1

echo "== syntax checks =="
sh -n "$ROOT/install.sh"
sh -n "$ROOT/bin/codex"
node --check "$ROOT/scripts/codex-proxy.js"
echo "ok"

echo "== --help exits 0 =="
sh "$ROOT/install.sh" --help >/dev/null
echo "ok"

echo "== --no-download without binary fails cleanly =="
if sh "$ROOT/install.sh" --no-download 2>/dev/null; then
  echo "FAIL: expected error" >&2; exit 1
fi
echo "ok"

echo "== proxy script syntax + startup =="
READY="$TEST_HOME/proxy.ready"
( CODEX_PROXY_READY_FILE="$READY" node "$ROOT/scripts/codex-proxy.js" 18991 & echo $! > "$TEST_HOME/proxy.pid" )
i=0
while [ ! -f "$READY" ] && [ $i -lt 30 ]; do sleep 0.2; i=$((i+1)); done
[ -f "$READY" ] || { echo "FAIL: proxy did not start" >&2; exit 1; }
# CONNECT tunnel through the proxy reaches a real host (DNS via bionic)
if curl -fsS -x http://127.0.0.1:18991 https://api.openai.com/v1/models -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|401|403)$'; then
  echo "ok (proxy tunnels + DNS works)"
else
  echo "FAIL: proxy tunnel test" >&2; kill "$(cat "$TEST_HOME/proxy.pid")" 2>/dev/null || true; exit 1
fi
kill "$(cat "$TEST_HOME/proxy.pid")" 2>/dev/null || true

echo "== dry wiring (no download) =="
mkdir -p "$TEST_HOME/bin/codex-runtime"
printf '#!/bin/sh\n[ "$1" = "--version" ] && echo "codex-cli 0.148.0 (test stub)"\n' > "$TEST_HOME/bin/codex-runtime/codex"
chmod 755 "$TEST_HOME/bin/codex-runtime/codex"
CODEX_TERMUX_INSTALL_DIR="$TEST_HOME/bin" sh "$ROOT/install.sh" --no-download >/dev/null
[ -x "$TEST_HOME/bin/codex" ] || { echo "FAIL: launcher missing" >&2; exit 1; }
[ -f "$TEST_HOME/bin/codex-runtime/codex-proxy.js" ] || { echo "FAIL: proxy script missing" >&2; exit 1; }
echo "== launcher end-to-end (starts proxy + runs codex) =="
[ "$("$TEST_HOME/bin/codex" --version)" = "codex-cli 0.148.0 (test stub)" ] || { echo "FAIL: launcher exec" >&2; exit 1; }
echo "ok"

echo "== uninstall =="
CODEX_TERMUX_INSTALL_DIR="$TEST_HOME/bin" sh "$ROOT/install.sh" --uninstall >/dev/null
[ ! -e "$TEST_HOME/bin/codex" ] || { echo "FAIL: launcher left behind" >&2; exit 1; }
echo "ok"

echo "all codex-termux smoke tests passed"