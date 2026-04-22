#!/usr/bin/env node
// @wbx-modified copilot-a3f7 | 2026-04-21 | Read API key from env, never embed | prev: copilot-a3f7@2026-04-21
// mcp-proxy.mjs — stdio-to-SSE bridge for teamai-brain MCP server
// Bridges VS Code stdio MCP client to the SSE-based server with X-API-Key auth.

const SSE_URL = process.env.MORTGAGETECH_BRAIN_URL || 'https://teamai-brain-app.redmeadow-3ceab978.eastus2.azurecontainerapps.io/sse';
const API_KEY = process.env.MORTGAGETECH_BRAIN_KEY;

if (!API_KEY) {
  process.stderr.write('[mcp-proxy] ERROR: MORTGAGETECH_BRAIN_KEY env var not set. Re-run the workstation installer to configure your key.\n');
  process.exit(2);
}

const RECONNECT_MIN_MS = 1000;
const RECONNECT_MAX_MS = 30000;
const POST_MAX_ATTEMPTS = 5;
const POST_RETRY_BASE_MS = 500;

let messageEndpoint = null;
let endpointResolvers = [];
function waitForEndpoint() {
  if (messageEndpoint) return Promise.resolve();
  return new Promise(resolve => endpointResolvers.push(resolve));
}
function setEndpoint(url) {
  messageEndpoint = url;
  const resolvers = endpointResolvers;
  endpointResolvers = [];
  for (const r of resolvers) r();
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

// --- SSE Connection with auto-reconnect ---
async function sseLoop() {
  let backoff = RECONNECT_MIN_MS;
  while (true) {
    try {
      const resp = await fetch(SSE_URL, {
        headers: { 'X-API-Key': API_KEY, 'Accept': 'text/event-stream' },
      });
      if (!resp.ok) {
        process.stderr.write(`[mcp-proxy] SSE connect ${resp.status} ${resp.statusText}; retry in ${backoff}ms\n`);
        await sleep(backoff);
        backoff = Math.min(backoff * 2, RECONNECT_MAX_MS);
        continue;
      }

      backoff = RECONNECT_MIN_MS; // reset on successful connect
      const reader = resp.body.getReader();
      const decoder = new TextDecoder();
      let buf = '';
      let currentEvent = null;
      let currentData = [];

      function dispatch() {
        const type = currentEvent || 'message';
        const data = currentData.join('\n');
        currentEvent = null;
        currentData = [];
        if (type === 'endpoint') {
          const base = new URL(SSE_URL);
          const url = new URL(data, base.origin).href;
          setEndpoint(url);
          process.stderr.write(`[mcp-proxy] endpoint: ${url}\n`);
        } else if (type === 'message') {
          process.stdout.write(data + '\n');
        }
      }

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          process.stderr.write('[mcp-proxy] SSE stream closed; reconnecting\n');
          messageEndpoint = null;
          break;
        }
        buf += decoder.decode(value, { stream: true });
        const lines = buf.split('\n');
        buf = lines.pop();
        for (const line of lines) {
          if (line.startsWith('event:')) currentEvent = line.slice(6).trim();
          else if (line.startsWith('data:')) currentData.push(line.slice(5).trimStart());
          else if (line === '' || line === '\r') {
            if (currentData.length > 0) dispatch();
          }
        }
      }
    } catch (err) {
      process.stderr.write(`[mcp-proxy] SSE error: ${err.message}; retry in ${backoff}ms\n`);
      messageEndpoint = null;
    }
    await sleep(backoff);
    backoff = Math.min(backoff * 2, RECONNECT_MAX_MS);
  }
}

// --- POST a single message with retries (waits for endpoint if mid-reconnect) ---
async function sendMessage(line) {
  for (let attempt = 1; attempt <= POST_MAX_ATTEMPTS; attempt++) {
    try {
      await waitForEndpoint();
      const r = await fetch(messageEndpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: line,
      });
      if (r.ok) return;
      const body = await r.text();
      process.stderr.write(`[mcp-proxy] POST ${r.status} attempt ${attempt}: ${body.slice(0, 200)}\n`);
      // 4xx (other than 401/408/429) won't recover — bail without retry storm
      if (r.status >= 400 && r.status < 500 && ![401, 408, 429].includes(r.status)) return;
    } catch (err) {
      process.stderr.write(`[mcp-proxy] POST error attempt ${attempt}: ${err.message}\n`);
      messageEndpoint = null; // force re-wait for fresh endpoint
    }
    await sleep(POST_RETRY_BASE_MS * Math.pow(2, attempt - 1));
  }
  process.stderr.write(`[mcp-proxy] POST giving up after ${POST_MAX_ATTEMPTS} attempts\n`);
}

// --- Stdin → POST ---
async function pumpStdin() {
  await waitForEndpoint();
  process.stderr.write('[mcp-proxy] ready — forwarding stdin\n');
  let buf = '';
  for await (const chunk of process.stdin) {
    buf += typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    const lines = buf.split('\n');
    buf = lines.pop();
    for (const line of lines) {
      if (!line.trim()) continue;
      // fire-and-forget so a slow message doesn't block the next one
      sendMessage(line).catch(e => process.stderr.write(`[mcp-proxy] sendMessage fatal: ${e.message}\n`));
    }
  }
  process.stderr.write('[mcp-proxy] stdin closed; exiting\n');
  process.exit(0);
}

process.stdin.setEncoding('utf8');
process.on('uncaughtException', e => process.stderr.write(`[mcp-proxy] uncaught: ${e.stack || e.message}\n`));
process.on('unhandledRejection', e => process.stderr.write(`[mcp-proxy] unhandled: ${e && (e.stack || e.message) || e}\n`));

sseLoop().catch(e => process.stderr.write(`[mcp-proxy] sseLoop fatal: ${e.message}\n`));
pumpStdin().catch(e => process.stderr.write(`[mcp-proxy] pumpStdin fatal: ${e.message}\n`));
