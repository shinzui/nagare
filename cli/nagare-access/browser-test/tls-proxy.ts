import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync } from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import tls from 'node:tls';
import { probePort, startProbeServer } from './probe-server';

const certDir = path.join(__dirname, '.certs');

function throwawayCertificate() {
  mkdirSync(certDir, { recursive: true });
  const keyPath = path.join(certDir, 'key.pem');
  const certPath = path.join(certDir, 'cert.pem');
  execFileSync(
    'openssl',
    [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
      '-keyout', keyPath, '-out', certPath, '-subj', '/CN=example.test',
      '-addext', 'subjectAltName=DNS:*.example.test,DNS:example.test',
    ],
    { stdio: 'ignore' },
  );
  return { key: readFileSync(keyPath), cert: readFileSync(certPath) };
}

// Terminates TLS the way Envoy does and routes by hostname.
function portFor(host: string): number {
  if (host.startsWith('probe')) return probePort;
  if (host === 'legacy.example.test') return 18782;
  return 18780;
}

// `*.example.test` must reach loopback in all three engines, with HTTPS and a
// real parent domain for the cookies. Hosts files are off limits and resolver
// flags are Chromium-only, but every engine honours an HTTP CONNECT proxy.
export default async function globalSetup() {
  const secureContext = tls.createSecureContext(throwawayCertificate());
  const proxy = http.createServer((_req, res) => {
    res.writeHead(400);
    res.end();
  });
  proxy.on('connect', (req, client: net.Socket, head: Buffer) => {
    const host = (req.url ?? '').split(':')[0];
    client.on('error', () => client.destroy());
    client.write('HTTP/1.1 200 Connection Established\r\n\r\n', () => {
      if (head.length > 0) client.unshift(head);
      const secure = new tls.TLSSocket(client, { isServer: true, secureContext });
      const backend = net.connect(portFor(host), '127.0.0.1');
      for (const socket of [secure, backend]) socket.on('error', () => socket.destroy());
      secure.on('close', () => backend.destroy());
      backend.on('close', () => secure.destroy());
      secure.pipe(backend).pipe(secure);
    });
  });
  await new Promise<void>((resolve) => proxy.listen(18790, '127.0.0.1', resolve));
  const probe = await startProbeServer();
  return async () => {
    proxy.closeAllConnections();
    probe.closeAllConnections();
    await Promise.all([
      new Promise((resolve) => proxy.close(resolve)),
      new Promise((resolve) => probe.close(resolve)),
    ]);
  };
}
