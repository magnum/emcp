if (!globalThis.__emcpBrowserContent) {
  globalThis.__emcpBrowserContent = true;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    run(message)
      .then((result) => sendResponse({ ok: true, result }))
      .catch((error) => sendResponse({ ok: false, error: error.message || "page command failed" }));
    return true;
  });
}

async function run(message) {
  const tool = message?.tool;
  const args = message?.args || {};
  const maxChars = Number(message?.max_chars) > 0 ? Number(message.max_chars) : 12000;
  const root = args.selector ? document.querySelector(args.selector) : document.body;
  if (args.selector && !root) throw new Error(`selector not found: ${args.selector}`);

  switch (tool) {
    case "browser_get_dom":
      return { html: clip(root === document.body ? document.documentElement.outerHTML : root.outerHTML, maxChars) };
    case "browser_get_text":
      return { text: clip(root.innerText || "", maxChars) };
    case "browser_query":
      return { elements: queryElements(args.selector, maxChars) };
    case "browser_read_table":
      return readTables(args.selector, maxChars);
    case "browser_accessibility_snapshot":
      return { nodes: accessibilityNodes(root, maxChars) };
    case "browser_click":
      root.click();
      return { clicked: args.selector };
    case "browser_type":
      setValue(root, args.text ?? "");
      return { typed: true };
    case "browser_set_value":
      setValue(root, args.value ?? "");
      return { value_set: true };
    case "browser_select":
      selectOption(root, args.value ?? "");
      return { selected: args.value };
    case "browser_check":
      if (!("checked" in root)) throw new Error("element is not a checkbox or radio");
      root.checked = args.checked !== false;
      root.dispatchEvent(new Event("input", { bubbles: true }));
      root.dispatchEvent(new Event("change", { bubbles: true }));
      return { checked: root.checked };
    case "browser_scroll":
      if (args.selector) root.scrollBy(Number(args.x) || 0, Number(args.y) || 0);
      else window.scrollBy(Number(args.x) || 0, Number(args.y) || 0);
      return { scrolled: true };
    case "browser_wait_for":
      await waitFor(args.selector, Number(args.timeout_ms) || 10000);
      return { found: args.selector };
    case "browser_eval_readonly":
      if (message.allow_eval !== true) throw new Error("browser_eval_readonly is disabled");
      return { value: evalInPage(args.expression) };
    default:
      throw new Error(`unsupported page tool: ${tool}`);
  }
}

function queryElements(selector, maxChars) {
  return [...document.querySelectorAll(selector)].slice(0, 50).map((element) => ({
    tag: element.tagName.toLowerCase(),
    text: clip(element.innerText || "", 200),
    html: clip(element.outerHTML || "", Math.min(maxChars, 500)),
  }));
}

function readTables(selector, maxChars) {
  const nodes = selector
    ? [...document.querySelectorAll(selector)]
    : [...document.querySelectorAll("table, ul, ol")];
  const tables = nodes.slice(0, 10).map((node) => {
    if (node.tagName === "TABLE") return htmlTable(node);
    return listTable(node);
  });
  const csv = tables.map((table) => table.rows.map((row) => row.map(csvCell).join(",")).join("\n")).join("\n\n");
  return { tables, csv: clip(csv, maxChars) };
}

function htmlTable(table) {
  const rows = [...table.rows].map((row) => [...row.cells].map((cell) => (cell.innerText || "").trim()));
  return { kind: "table", rows };
}

function listTable(list) {
  const rows = [...list.querySelectorAll(":scope > li")].map((item) => [(item.innerText || "").trim()]);
  return { kind: "list", rows };
}

function csvCell(value) {
  const text = String(value ?? "");
  return /[",\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
}

function accessibilityNodes(root, maxChars) {
  const scope = root === document.body ? document.body : root;
  const nodes = [];
  const walker = document.createTreeWalker(scope, NodeFilter.SHOW_ELEMENT);
  let count = 0;
  while (walker.nextNode() && count < 200) {
    const element = walker.currentNode;
    const role = element.getAttribute("role") || implicitRole(element);
    const name = element.getAttribute("aria-label") || element.getAttribute("alt") || "";
    const text = (element.innerText || "").trim().slice(0, 120);
    if (!role && !name && !text) continue;
    if (element.children.length > 0 && !name && text.length > 120) continue;
    nodes.push({ role, name: name.slice(0, 120), text });
    count += 1;
  }
  const used = JSON.stringify(nodes).length;
  return used > maxChars ? nodes.slice(0, 40) : nodes;
}

function implicitRole(element) {
  const tag = element.tagName;
  if (tag === "A" && element.hasAttribute("href")) return "link";
  if (tag === "BUTTON") return "button";
  if (tag === "INPUT") return element.getAttribute("type") || "textbox";
  if (tag === "TEXTAREA") return "textbox";
  if (tag === "SELECT") return "combobox";
  if (tag === "H1" || tag === "H2" || tag === "H3") return "heading";
  if (tag === "IMG") return "image";
  return "";
}

function setValue(element, value) {
  if (element.isContentEditable) {
    element.textContent = value;
  } else if ("value" in element) {
    element.focus();
    element.value = value;
  } else {
    throw new Error("element does not accept text");
  }
  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
}

function selectOption(element, value) {
  if (element.tagName !== "SELECT") throw new Error("element is not a select");
  const option = [...element.options].find((item) => item.value === value || item.label === value || item.text === value);
  if (!option) throw new Error("option not found");
  element.value = option.value;
  element.dispatchEvent(new Event("input", { bubbles: true }));
  element.dispatchEvent(new Event("change", { bubbles: true }));
}

function waitFor(selector, timeoutMs) {
  if (document.querySelector(selector)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      observer.disconnect();
      reject(new Error(`timed out waiting for ${selector}`));
    }, timeoutMs);
    const observer = new MutationObserver(() => {
      if (!document.querySelector(selector)) return;
      clearTimeout(timer);
      observer.disconnect();
      resolve();
    });
    observer.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
  });
}

function evalInPage(expression) {
  const value = (0, eval)(String(expression ?? ""));
  return clip(JSON.stringify(value), 12000);
}

function clip(value, max) {
  const text = String(value ?? "");
  return text.length > max ? `${text.slice(0, max)}…` : text;
}
