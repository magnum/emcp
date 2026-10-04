const CHANNEL = JSON.stringify({ channel: "BrowserChannel" });
const MAX_DOWNLOAD_BYTES = 1_500_000;

let socket = null;
let config = null;
let heartbeatTimer = null;
let reconnectTimer = null;
let attempt = 0;
let stopped = false;
let superseded = false;
let online = false;
let busyCount = 0;
let flags = { log: true, enabled: true };

const SKIPPED = "not executed because enabled is set to false";

const TOOLBAR_ICONS = {
  offline: { 16: "icons/gray16.png", 48: "icons/gray48.png", 128: "icons/gray128.png" },
  online: { 16: "icons/green16.png", 48: "icons/green48.png", 128: "icons/green128.png" },
  busy: { 16: "icons/yellow16.png", 48: "icons/yellow48.png", 128: "icons/yellow128.png" },
  disabled: { 16: "icons/purple16.png", 48: "icons/purple48.png", 128: "icons/purple128.png" },
};

chrome.runtime.onInstalled.addListener(restore);
chrome.runtime.onStartup.addListener(restore);
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes.emcpBrowserFlags) return;
  applyFlags(changes.emcpBrowserFlags.newValue);
  setPresence(online ? "online" : "offline");
});
restore();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!message || typeof message !== "object") return;

  if (message.kind === "status") {
    sendResponse(publicStatus());
    return;
  }

  if (message.kind === "connect") {
    superseded = false;
    stopped = false;
    attempt = 0;
    saveAndConnect(message.config).then(
      () => sendResponse({ ok: true }),
      (error) => sendResponse({ ok: false, error: error.message }),
    );
    return true;
  }

  if (message.kind === "disconnect") {
    disconnect(true).then(() => sendResponse({ ok: true }));
    return true;
  }

  if (message.kind === "flags") {
    applyFlags(message);
    chrome.storage.local.set({ emcpBrowserFlags: flags });
    setPresence(online ? "online" : "offline");
    sendResponse(publicStatus());
  }
});

function publicStatus() {
  return {
    online,
    paired: Boolean(config?.token),
    superseded,
    instanceId: config?.instance_id || null,
    log: flags.log,
    enabled: flags.enabled,
  };
}

async function restore() {
  const stored = await chrome.storage.local.get(["emcpBrowser", "emcpBrowserFlags"]);
  applyFlags(stored.emcpBrowserFlags);
  setPresence("offline");
  config = stored.emcpBrowser || null;
  if (config?.token && config.ws && config.instance_id) connect();
}

function applyFlags(saved) {
  flags = {
    log: saved?.log !== false,
    enabled: saved?.enabled !== false,
  };
}

function setPresence(state) {
  const name = flags.enabled === false ? "disabled" : (busyCount > 0 ? "busy" : state);
  chrome.action.setIcon({ path: TOOLBAR_ICONS[name] || TOOLBAR_ICONS.offline });
  const titles = {
    offline: "eMCP Browser — offline",
    online: "eMCP Browser — online",
    busy: "eMCP Browser — working",
    disabled: "eMCP Browser — disabled",
  };
  chrome.action.setTitle({ title: titles[name] || titles.offline });
}

function beginWork() {
  busyCount += 1;
  setPresence("busy");
}

function endWork() {
  busyCount = Math.max(0, busyCount - 1);
  setPresence(online ? "online" : "offline");
}

async function saveAndConnect(next) {
  config = {
    ws: String(next.ws || ""),
    instance_id: next.instance_id,
    token: String(next.token || ""),
    origins: Array.isArray(next.origins) ? next.origins : [],
    heartbeat: Number(next.heartbeat) > 0 ? Number(next.heartbeat) : 15,
  };
  await chrome.storage.local.set({ emcpBrowser: config });
  connect();
}

async function disconnect(clear) {
  stopped = true;
  superseded = false;
  clearTimers();
  if (socket) socket.close();
  socket = null;
  online = false;
  busyCount = 0;
  setPresence("offline");
  if (clear) {
    config = null;
    await chrome.storage.local.remove("emcpBrowser");
  }
}

function connect() {
  if (!config?.token || stopped) return;
  clearTimers();
  if (socket) socket.close();

  const url = new URL(config.ws);
  url.searchParams.set("instance_id", String(config.instance_id));
  url.searchParams.set("token", config.token);
  if (url.protocol === "http:") url.protocol = "ws:";
  if (url.protocol === "https:") url.protocol = "wss:";

  socket = new WebSocket(url.toString(), ["actioncable-v1-json"]);
  socket.onopen = () => {
    attempt = 0;
  };
  socket.onmessage = (event) => onFrame(event.data);
  socket.onclose = () => {
    online = false;
    clearTimers();
    setPresence("offline");
    if (!stopped && !superseded) scheduleReconnect();
  };
  socket.onerror = () => socket?.close();
}

function onFrame(raw) {
  let frame;
  try {
    frame = JSON.parse(raw);
  } catch (_error) {
    return;
  }

  if (frame.type === "welcome") {
    socket.send(JSON.stringify({ command: "subscribe", identifier: CHANNEL }));
    return;
  }
  if (frame.type === "confirm_subscription") {
    online = true;
    startHeartbeat();
    setPresence("online");
    return;
  }
  if (frame.type === "ping" || frame.type === "reject_subscription") return;
  if (!frame.message) return;

  const message = frame.message;
  if (message.kind === "superseded") {
    superseded = true;
    stopped = true;
    online = false;
    clearTimers();
    setPresence("offline");
    socket?.close();
    return;
  }
  if (message.kind === "heartbeat" || !message.tool || !message.request_id) return;

  runCommand(message).then(
    (result) => reply(message.request_id, { ok: true, result }),
    (error) => reply(message.request_id, { ok: false, error: error.message || "browser command failed" }),
  );
}

function reply(requestId, body) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return;
  socket.send(JSON.stringify({
    command: "message",
    identifier: CHANNEL,
    data: JSON.stringify({ request_id: requestId, ...body }),
  }));
}

function startHeartbeat() {
  clearInterval(heartbeatTimer);
  const seconds = config?.heartbeat || 15;
  heartbeatTimer = setInterval(() => {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    socket.send(JSON.stringify({
      command: "message",
      identifier: CHANNEL,
      data: JSON.stringify({ kind: "heartbeat" }),
    }));
  }, seconds * 1000);
}

function scheduleReconnect() {
  const delay = Math.min(30_000, 1000 * (2 ** attempt));
  attempt += 1;
  reconnectTimer = setTimeout(connect, delay);
}

function clearTimers() {
  clearInterval(heartbeatTimer);
  clearTimeout(reconnectTimer);
  heartbeatTimer = null;
  reconnectTimer = null;
}

async function runCommand(message) {
  if (flags.enabled === false) {
    await logCommand(message, SKIPPED);
    throw new Error(SKIPPED);
  }
  await logCommand(message);
  beginWork();
  try {
    return await handleCommand(message);
  } finally {
    endWork();
  }
}

async function logCommand(message, extra) {
  if (flags.log === false) return;
  const line = extra ? `${commandLine(message)} — ${extra}` : commandLine(message);
  console.log(line);
  try {
    const tabId = message.args?.tab_id;
    const tab = tabId
      ? await chrome.tabs.get(tabId)
      : (await chrome.tabs.query({ active: true, lastFocusedWindow: true }))[0];
    if (!tab?.id) return;
    await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: (text) => console.log(text),
      args: [line],
    });
  } catch (_error) {
    // The service worker console already has the line.
  }
}

function commandLine(message) {
  return `emcp ${message.tool} ${JSON.stringify(message.args || {})}`;
}

async function handleCommand(message) {
  const tool = message.tool;
  const args = message.args || {};
  const origins = message.allowed_origins || config?.origins || [];

  if (tool === "browser_status") {
    return { connected: true, paired: true, version: "0.1.0" };
  }

  if (tool === "browser_list_tabs") {
    const tabs = await chrome.tabs.query({});
    return {
      tabs: tabs
        .filter((tab) => allowedUrl(tab.url, origins))
        .map(tabSummary),
    };
  }

  if (tool === "browser_screenshot") {
    const tab = await resolveTab(args.tab_id);
    ensureAllowed(tab.url, origins);
    if (!tab.active) throw new Error("Screenshot captures the visible tab. Switch to it first.");
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
    return { url: tab.url, tab_id: tab.id, image: dataUrl };
  }

  if (tool === "browser_navigate" || tool === "browser_open_tab") {
    ensureAllowed(args.url, origins);
    const tab = tool === "browser_open_tab"
      ? await chrome.tabs.create({ url: args.url })
      : await chrome.tabs.update(args.tab_id || (await resolveTab()).id, { url: args.url });
    return tabSummary(tab);
  }

  if (tool === "browser_switch_tab") {
    const tab = await chrome.tabs.get(args.tab_id);
    ensureAllowed(tab.url, origins);
    const updated = await chrome.tabs.update(tab.id, { active: true });
    return tabSummary(updated);
  }

  if (tool === "browser_close_tab") {
    const tab = await chrome.tabs.get(args.tab_id);
    ensureAllowed(tab.url, origins);
    await chrome.tabs.remove(tab.id);
    return { closed: tab.id, url: tab.url };
  }

  if (tool === "browser_download" || tool === "browser_get_file") {
    ensureAllowed(args.url, origins);
    return downloadFile(args.url);
  }

  const tab = await resolveTab(args.tab_id);
  ensureAllowed(tab.url, origins);
  if (tool === "browser_get_url") return tabSummary(tab);
  if (tool === "browser_eval_readonly") {
    if (message.allow_eval !== true) throw new Error("browser_eval_readonly is disabled");
    const [injected] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      world: "MAIN",
      func: (expression) => {
        try {
          const value = (0, eval)(String(expression ?? ""));
          const text = JSON.stringify(value);
          return { ok: true, value: text.length > 12000 ? `${text.slice(0, 12000)}…` : text };
        } catch (error) {
          return { ok: false, error: error.message };
        }
      },
      args: [args.expression || ""],
    });
    if (!injected?.result?.ok) throw new Error(injected?.result?.error || "eval failed");
    return { url: tab.url, tab_id: tab.id, value: injected.result.value };
  }

  await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] });
  const page = await chrome.tabs.sendMessage(tab.id, {
    tool,
    args,
    max_chars: message.max_chars || 12000,
    allow_eval: message.allow_eval === true,
  });
  if (!page?.ok) throw new Error(page?.error || "page command failed");
  return { url: tab.url, tab_id: tab.id, ...page.result };
}

async function resolveTab(tabId) {
  if (tabId) return chrome.tabs.get(tabId);
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  if (!tab?.id) throw new Error("No active tab");
  return tab;
}

function tabSummary(tab) {
  return { tab_id: tab.id, url: tab.url || "", title: tab.title || "", active: Boolean(tab.active) };
}

function ensureAllowed(url, origins) {
  if (!allowedUrl(url, origins)) throw new Error("Origin is not on the allowlist");
}

function allowedUrl(url, origins) {
  const patterns = (origins?.length ? origins : ["https://*/*"]).map(normalizePattern).filter(Boolean);
  let parsed;
  try {
    parsed = new URL(url);
  } catch (_error) {
    return false;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:" && parsed.protocol !== "file:") return false;
  return patterns.some((pattern) => patternMatches(pattern, parsed));
}

function normalizePattern(entry) {
  let value = String(entry || "").trim();
  if (!value) return null;
  if (!value.includes("://")) value = `*://${value}/*`;
  const rest = value.slice(value.indexOf("://") + 3);
  if (!rest.includes("/")) value = `${value.replace(/\/$/, "")}/*`;
  return value;
}

function patternMatches(pattern, url) {
  const match = pattern.match(/^(\*|https?|file):\/\/(\*|(?:\*\.)?[^/:*]+)(?::(\d+))?(\/.*)$/i);
  if (!match) return false;
  const scheme = match[1].toLowerCase();
  const hostPattern = match[2].toLowerCase();
  const port = match[3] ? Number(match[3]) : null;
  const pathPattern = match[4];
  const schemeOk = scheme === "*"
    ? url.protocol === "http:" || url.protocol === "https:"
    : `${scheme}:` === url.protocol;
  if (!schemeOk) return false;
  const host = url.hostname.toLowerCase();
  const hostOk = hostPattern === "*" ||
    (hostPattern.startsWith("*.")
      ? host === hostPattern.slice(2) || host.endsWith(`.${hostPattern.slice(2)}`)
      : host === hostPattern);
  if (!hostOk) return false;
  if (port) {
    const actualPort = url.port ? Number(url.port) : (url.protocol === "https:" ? 443 : 80);
    if (actualPort !== port) return false;
  }
  const path = `${url.pathname || "/"}${url.search}`;
  const body = pathPattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${body}$`, "i").test(path);
}

async function downloadFile(url) {
  const response = await fetch(url, { credentials: "include" });
  if (!response.ok) throw new Error(`download failed (${response.status})`);
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength > MAX_DOWNLOAD_BYTES) throw new Error("File is larger than 1.5 MB");
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  }
  const name = filenameFrom(response, url);
  return {
    url,
    filename: name,
    content_type: response.headers.get("content-type") || "application/octet-stream",
    bytes: buffer.byteLength,
    content_base64: btoa(binary),
  };
}

function filenameFrom(response, url) {
  const header = response.headers.get("content-disposition") || "";
  const match = header.match(/filename="?([^";]+)"?/i);
  if (match) return match[1];
  try {
    const path = new URL(url).pathname.split("/").filter(Boolean).pop();
    return path || "download";
  } catch (_error) {
    return "download";
  }
}
