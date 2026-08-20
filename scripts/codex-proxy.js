#!/usr/bin/env node
//
// codex-termux DNS proxy — a minimal HTTP(S) CONNECT proxy that resolves
// hostnames through Android's own resolver (bionic via Node).
//
// Why: the official codex binary is a fully-static musl binary. musl's
// getaddrinfo reads /etc/resolv.conf, which on Android is /system/etc
// (read-only, missing) — so codex's DNS lookups fail ("failed to lookup
// address information"). Android apps resolve DNS through netd, which only
// bionic (and tools linked against it, like Node) can reach. Routing codex's
// traffic through this local proxy fixes DNS: codex connects to 127.0.0.1
// (no DNS needed), and this proxy resolves the real hostname via Node.
//
// Usage: node codex-proxy.js [port]   (default 18080)
//
const http = require('http');
const net = require('net');

const PORT = Number(process.argv[2] || 18080);

// CONNECT tunneling — this is what HTTPS/wss traffic uses. We resolve the
// hostname here (via bionic) and splice a raw TCP tunnel to the target.
const server = http.createServer((req, res) => {
  // Plain HTTP (non-CONNECT) requests: forward them to the target.
  let host = req.headers.host || '';
  const url = new URL(req.url, 'http://' + host);
  const upstream = net.connect(Number(url.port || 80), url.hostname, () => {
    const head = `${req.method} ${url.pathname + url.search} HTTP/${req.httpVersion}\r\n`;
    let body = Buffer.alloc(0);
    let writeReq = head;
    const headers = { ...req.headers };
    headers.host = url.host;
    for (const [k, v] of Object.entries(headers)) writeReq += `${k}: ${v}\r\n`;
    writeReq += '\r\n';
    req.on('data', (d) => (body = Buffer.concat([body, d])));
    req.on('end', () => upstream.write(Buffer.concat([Buffer.from(writeReq), body])));
    upstream.pipe(res);
  });
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
  req.on('error', () => upstream.destroy());
});

server.on('connect', (req, clientSocket, head) => {
  const [host, portStr] = req.url.split(':');
  const port = Number(portStr) || 443;
  const upstream = net.connect(port, host, () => {
    clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });
  upstream.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
  clientSocket.on('close', () => upstream.destroy());
  upstream.on('close', () => clientSocket.destroy());
});

server.on('error', (e) => {
  // Port already in use — fine, another instance is serving it.
  if (e.code === 'EADDRINUSE') process.exit(0);
  console.error(e);
  process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
  const readyFile = process.env.CODEX_PROXY_READY_FILE;
  if (readyFile) require('fs').writeFileSync(readyFile, String(PORT));
});