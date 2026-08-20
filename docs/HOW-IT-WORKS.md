# How it works

OpenAI Codex CLI ships as a fully static musl binary
(`codex-aarch64-unknown-linux-musl.tar.gz`). Static means it links no
shared libraries at all — so unlike Claude Code (which needs a glibc bridge)
it runs on Termux's bionic libc directly, with zero dependencies.

But static has a price: everything the libc would normally do is compiled
in, including DNS resolution. That's where Android breaks codex.

## Problem 1 — DNS

musl's `getaddrinfo` reads `/etc/resolv.conf`. On Android that path is
`/system/etc/resolv.conf` — and Android doesn't ship one. `/etc` is a
symlink to the read-only `/system/etc`, so you can't write a resolv.conf
either. The result is codex failing instantly:

```
failed to lookup address information: Try again
```

Android resolves DNS through `netd` (the network daemon), and the only way
to reach it is bionic — the libc everything in Termux is linked against.

**The fix: a local DNS proxy.** The launcher starts a tiny HTTP(S) CONNECT
proxy written in Node (bionic, so it resolves DNS fine) listening on
`127.0.0.1:18080`:

```
codex (static musl) ──HTTPS_PROXY──▶ codex-proxy.js (Node/bionic)
                                          │  getaddrinfo → netd → DNS
                                          ▼
                                    api.openai.com:443
```

Codex connects to the proxy by IP literal (no DNS needed for that hop); the
proxy resolves the real hostname via Android's resolver and splices a raw
TCP tunnel through. WebSocket (`wss://`) and HTTPS both work — both use
CONNECT tunneling.

## Problem 2 — TLS

Static binaries also have no CA store. Android keeps CAs in a system store
that a static musl binary can't read. The launcher sets:

```
SSL_CERT_FILE=$PREFIX/etc/tls/cert.pem
```

Termux ships a full CA bundle there (the same one curl/openssl use).

## Problem 3 — sandbox

Codex's default sandbox uses bubblewrap, which needs kernel features Android
doesn't expose. On Android the sandbox simply can't start. The first-run
`~/.codex/config.toml` therefore sets:

```toml
sandbox_mode = "danger-full-access"
check_for_update_on_startup = false
```

`danger-full-access` runs codex without sandboxing (the same mode desktop
users get when sandboxing is unavailable). The update check is disabled
because codex's updater would fetch a build that doesn't work in the Termux
context — upgrade with the installer instead.

## What gets installed

| Path | What it is |
|---|---|
| `~/bin/codex-runtime/codex` | The official `codex-aarch64-unknown-linux-musl` release binary (unmodified) |
| `~/bin/codex-runtime/codex-proxy.js` | The Node DNS proxy (fetched from this repo) |
| `~/bin/codex` | POSIX sh launcher: starts proxy on demand, exports `HTTPS_PROXY`/`SSL_CERT_FILE`, execs the binary |
| `~/.codex/config.toml` | First-run sandbox + update defaults (only written if you have no config) |
| PATH line + completions | bash → `~/.bashrc` + `/data/data/com.termux/files/usr/etc/bash_completion.d/`, zsh → `~/.zshrc` + `~/.zsh/completions/`, fish → `fish_add_path` + `~/.config/fish/completions/` |
| `nodejs` package | Only the DNS proxy needs it; installed automatically if missing |

The proxy binary (`~/bin/codex-runtime/codex`) is invoked by the launcher as
`codex`, so the kernel process name stays `codex` — agent runtimes like herdr
that identify agents by process name work as expected.

## What's *not* done

No proot, no containers, no patched binaries, no `LD_PRELOAD` shims, no
emulation. The codex binary on disk is byte-identical to upstream, and every
download is verified against the sha256 digest GitHub publishes for the
release asset. The only extra code in the picture is the 60-line DNS proxy
and the launcher.

## Verification

Verified on Android / aarch64 / Termux (F-Droid): the binary runs natively
(`codex --version` → `codex-cli 0.148.0`), and with the proxy +
`SSL_CERT_FILE` the full network path reaches `api.openai.com` (auth is the
only remaining gate). Interactive use needs a logged-in session
(`codex login` or `OPENAI_API_KEY`).