import { createHash } from 'node:crypto';
import http from 'node:http';

export const probePort = 18784;

const webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';
const newCookie = 'probe=new; Path=/; Secure; SameSite=Lax';

// A stand-in for a site behind the enforcer: anything under /r/ answers a
// request carrying the old cookie with a 307 and the new cookie, as the
// enforcer does. It pins what browsers do with that answer, which the design
// rests on. The TLS proxy in front gives it HTTPS.
export function startProbeServer(): Promise<http.Server> {
  const server = http.createServer((req, res) => {
    const url = new URL(req.url ?? '/', 'http://probe');
    const hasOldCookie = /(^|;\s*)probe=old(;|$)/.test(req.headers.cookie ?? '');
    const cors: Record<string, string> =
      url.pathname.includes('cors') && req.headers.origin
        ? {
            'Access-Control-Allow-Origin': req.headers.origin,
            'Access-Control-Allow-Credentials': 'true',
          }
        : {};
    if (url.pathname.startsWith('/r/') && hasOldCookie) {
      res.writeHead(307, {
        Location: req.url ?? '/',
        'Cache-Control': 'no-store',
        'Set-Cookie': newCookie,
        ...cors,
      });
      res.end();
    } else if (url.pathname === '/r/held') {
      // Held until the browser gives up, which is the point of the row.
      req.on('close', () => res.destroy());
    } else if (url.pathname.startsWith('/r/sse')) {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', ...cors });
      res.write('data: ready\n\n');
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', ...cors });
      res.end('<!doctype html><title>probe</title>ok');
    }
  });
  server.on('upgrade', (req, socket) => {
    const accept = createHash('sha1')
      .update(`${req.headers['sec-websocket-key']}${webSocketGuid}`)
      .digest('base64');
    // An upgraded socket is ours to read, or its close is never seen and the
    // server cannot shut down.
    socket.on('error', () => socket.destroy());
    socket.on('end', () => socket.destroy());
    socket.resume();
    socket.write(
      [
        'HTTP/1.1 101 Switching Protocols',
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Accept: ${accept}`,
        `Set-Cookie: ${newCookie}`,
        '',
        '',
      ].join('\r\n'),
    );
  });
  return new Promise((resolve) => server.listen(probePort, '127.0.0.1', () => resolve(server)));
}
