// run: node server.js --port 8787
// test: curl.exe "http://127.0.0.1:8787/notify?claude=true&chatgpt=true"

import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const scriptPath = join(scriptDir, "Reset-Notify.ps1");
const DEFAULT_PORT = 8787;
const HOST = "127.0.0.1";

const SERVICES = [
  ["claude", "Claude"],
  ["chatgpt", "ChatGPT"],
];

function resolvePort() {
  const args = process.argv.slice(2);
  const portFlagIndex = args.indexOf("--port");
  if (portFlagIndex !== -1 && args[portFlagIndex + 1]) {
    return Number(args[portFlagIndex + 1]);
  }

  const positional = args.find((arg) => !arg.startsWith("-"));
  if (positional) {
    return Number(positional);
  }

  if (process.env.PORT) {
    return Number(process.env.PORT);
  }

  return DEFAULT_PORT;
}

function formatTimestamp(date = new Date()) {
  const pad = (value) => String(value).padStart(2, "0");
  const year = date.getFullYear();
  const month = pad(date.getMonth() + 1);
  const day = pad(date.getDate());
  const hours = pad(date.getHours());
  const minutes = pad(date.getMinutes());
  return `${year}${month}${day} ${hours}:${minutes}`;
}

function notifyMessage(searchParams, now = new Date()) {
  const selected = new Set();

  for (const [key, value] of searchParams) {
    const service = SERVICES.find(([name]) => name === key.toLowerCase());
    if (!service || value.toLowerCase() !== "true" || selected.has(service[1])) {
      return null;
    }
    selected.add(service[1]);
  }

  if (selected.size === 0) {
    return null;
  }

  const names = SERVICES
    .map(([, label]) => label)
    .filter((label) => selected.has(label));

  return `Your sub has reset news: ${names.join(" | ")} ${formatTimestamp(now)}`;
}

function startNotify(message) {
  const child = spawn("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    scriptPath,
    "-message",
    message,
  ], {
    cwd: scriptDir,
    windowsHide: true,
    stdio: "ignore",
  });

  child.on("error", (err) => {
    console.error("Failed to start Reset-Notify.ps1:", err.message);
  });
}

const port = resolvePort();
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`Invalid port: ${port}`);
  process.exit(1);
}

const server = createServer((req, res) => {
  const url = new URL(req.url ?? "/", `http://${HOST}`);

  if (url.pathname !== "/notify") {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("Not Found");
    return;
  }

  if (req.method !== "GET") {
    res.writeHead(405, { Allow: "GET", "Content-Type": "text/plain" });
    res.end("Method Not Allowed");
    return;
  }

  const message = notifyMessage(url.searchParams);
  if (!message) {
    res.writeHead(400, { "Content-Type": "text/plain" });
    res.end("Bad Request");
    return;
  }

  startNotify(message);
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("OK");
});

server.listen(port, HOST, () => {
  console.log(`Listening for GET /notify on http://${HOST}:${port}/notify`);
});
