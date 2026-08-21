# FAQ

## Login / auth

### `codex login` fails or panics on Termux

The OAuth browser flow can be flaky on Android (it opens a terminal URL to
complete in your browser — the terminal browser handling is limited). Easiest
path: use an API key.

```bash
export OPENAI_API_KEY=sk-...
codex
```

or store it persistently in `~/.codex/auth.json`:

```json
{ "OPENAI_API_KEY": "sk-..." }
```

### Does `codex login` work at all?

It can work: it prints a URL you open in a real browser and paste back. If it
panics with a terminal/context error, use the API-key method above.

## DNS / proxy

### Do I need the proxy if I'm on Wi-Fi with a working resolver?

Yes. The problem isn't the network — it's that codex's static musl binary
can't reach Android's DNS resolver at all (`/etc/resolv.conf` doesn't exist
and `/etc` is read-only). The proxy is how DNS gets resolved, on any network.

### Why is there a `node` process running? Is it safe?

It's the DNS proxy (`codex-runtime/codex-proxy.js`), listening only on
`127.0.0.1:18080`. It's started on demand by the launcher, shuts down with
the terminal session, and only forwards your codex traffic. If you'd rather
not have it running, close the sessions that started it.

### Can I change the proxy port?

Yes: `export CODEX_TERMUX_PROXY_PORT=19090` before running `codex` (the
launcher and proxy both read it). The port is used only if it's free.

## Updating

### How do I upgrade codex?

```bash
sh install.sh            # re-run with CODEX_VERSION unset → latest
sh install.sh -v rust-v0.148.0
```

The auto-update check is disabled in `~/.codex/config.toml` (the updater
would fetch a non-Termux build). `codex update` may not work — use the
installer.

## Troubleshooting

### `curl: (22) ... 403` when fetching release metadata

GitHub's API rate limit (60 req/h per unauthenticated IP — shared on mobile
networks). Installers resolve versions via GitHub's `releases/latest`
redirect instead, which has no such limit — make sure you're running a
current `install.sh` (re-download it). If it still 403s, GitHub itself is
having issues; retry later. Note codex has no published checksum file, so on
API rate limits the installer skips checksum verification with a warning —
that's expected and non-fatal.

### `failed to lookup address information`

That's exactly the DNS failure the proxy fixes. Check the proxy is up:

```bash
curl -x http://127.0.0.1:18080 -s https://api.openai.com/v1/models -o /dev/null -w '%{http_code}\n'   # expect 401 (auth) — means DNS+TLS+proxy all work
```

If it hangs: `cat ~/bin/codex-runtime/codex-proxy.log` — and confirm you ran
`codex` (the launcher), not `~/bin/codex-runtime/codex` directly.

### `invalid peer certificate` / TLS errors

The launcher sets `SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem`. If you ran the
binary directly, you skipped it. Always use `codex` (the launcher).

### I ran the binary directly and it failed

Always invoke `codex` (the launcher) — it starts the proxy and sets
`HTTPS_PROXY`/`SSL_CERT_FILE`. The raw binary at
`~/bin/codex-runtime/codex` has none of that and will fail DNS/TLS.

### `sandbox` errors / codex says it can't create a sandbox

Your `~/.codex/config.toml` needs `sandbox_mode = "danger-full-access"`.
The installer writes this on first run only if the file didn't already exist;
if you had an old config, add it yourself. This is expected on Android —
bubblewrap can't run there.

### Does the sandbox mode mean codex is unsafe?

`danger-full-access` means codex's commands run with your full permissions,
same as your terminal — no extra confinement. That's the standard mode on
platforms without sandboxing support (Android included). Treat `codex` like
a trusted terminal session.

### codex hangs on startup or on the first request

Check network: `curl -I https://api.openai.com` should return an HTTP status.
The proxy only helps DNS — if your actual connection is down, requests will
retry/hang. Also confirm `OPENAI_API_KEY` or a login is set, otherwise codex
retries auth.

## Uninstall

```bash
sh install.sh --uninstall
```

Removes the launcher, DNS proxy, and binary. PATH/completion lines and
`~/.codex` session data are left in place (remove manually if desired).
The shared `nodejs` package is also left in place (other tools use it).