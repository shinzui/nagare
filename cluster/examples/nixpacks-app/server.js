// A tiny HTTP server with no Dockerfile — Nixpacks detects Node from
// package.json and builds a runnable image. It listens on $PORT (Knative injects
// the container port), defaulting to 8080 for local runs.
const http = require('http');

const port = process.env.PORT || 8080;

http
  .createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Hello from a Dockerfile-free app, built by Nixpacks\n');
  })
  .listen(port, () => console.log('nixpacks-app listening on ' + port));
