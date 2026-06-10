// Minimal HTTP server: echoes selected environment variables as plain text so a
// `curl` of the deployed URL shows env changes taking effect. No dependencies.
const http = require("http");

const SHOW = [
  "NAGARE_SERVICE_URL",
  "NAGARE_SERVICE_NAME",
  "NAGARE_NAMESPACE",
  "NAGARE_RELEASE_ID",
  "GREETING", // inline DSL var (shadows a managed GREETING — see the guide)
  "REGION", // managed var set via `nagarectl env set`
  "API_KEY", // managed secret set via `nagarectl secret set` (shown masked)
];

const server = http.createServer((_req, res) => {
  const lines = SHOW.map((k) => {
    const v = process.env[k];
    if (v === undefined) return `${k}=(unset)`;
    if (k === "API_KEY") return `${k}=${"*".repeat(Math.min(v.length, 8))} (set)`;
    return `${k}=${v}`;
  });
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end(lines.join("\n") + "\n");
});

server.listen(8080, () => console.log("envdemo listening on :8080"));
