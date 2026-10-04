# Browser

← [Back to project](https://github.com/magnum/emcp)

Drive a remote Chrome window from MCP. The eMCP Browser extension opens an
outbound WebSocket to this server. MCP clients use the normal instance
endpoint. Nothing on the remote PC has to accept inbound connections, so the
path works behind a VPN or a company firewall.

The extension reuses the Chrome profile that is already signed in. A typical
use is reading and filling a web app such as EDMA without a second login.

Use this on a company PC only with approval from IT and the data controller.
Page content can include personal data. Traffic stays on the self-hosted eMCP
server. The extension does not call any other host.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/browser/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

The extension WebSocket is ActionCable at `${EMCP_PUBLIC_URL}/cable`
(`actioncable-v1-json`). The pairing token is a query parameter because a
browser WebSocket cannot set a custom header. That token is filtered from
Rails logs. The reverse proxy must forward WebSocket upgrades on `/cable`.
Kamal-proxy does this by default. One Puma worker is the expected setup: the
live socket and the waiting MCP request share that process. Solid Cable still
delivers the command if more than one worker is running, and the reply is
also written to the Rails cache.

## Pair a Chrome window

1. On the instance Auth page, **Allowed origins** lists the pages the tools
   may touch. The default is `https://*/*`, every HTTPS site. Narrow it with
   comma-separated Chrome match patterns, for example
   `https://edma.example.it/*, *.example.it`.
2. Download the extension zip. Unzip it and load the folder at
   `chrome://extensions` with Developer mode on. A PC that cannot install
   software can still load an unpacked extension.
3. Click **Avvia pairing**. Scan the QR code from the extension popup, or
   paste the pairing payload. The popup asks Chrome for host permission on
   those origins. That permission is what lets the extension read the DOM and
   capture the visible tab.
4. The first successful connection marks the instance paired. Later
   reconnects reuse the saved token. The extension reconnects with backoff
   after a network drop and sends a heartbeat every `BROWSER_WS_HEARTBEAT`
   seconds (default 15).
5. **Salva** updates the allowlist, Allow write, Allow page JavaScript, timeout, and heartbeat without rotating the token. Allow page JavaScript is what enables `browser_eval_readonly`. **Re-authenticate
   service** revokes the token. A new connection replaces the previous one.

The zip is generic. The instance URL and token are not baked into it.

## Tools

Read tools are always registered. Write tools run only when the instance
allows writes (`BROWSER_ALLOW_WRITE` is the catalog default, same as the
other integrations). `browser_eval_readonly` also needs `BROWSER_ALLOW_EVAL`.

Read: `browser_status`, `browser_list_tabs`, `browser_get_url`,
`browser_get_dom`, `browser_get_text`, `browser_query`, `browser_read_table`,
`browser_accessibility_snapshot`, `browser_screenshot`,
`browser_eval_readonly`.

Write: `browser_navigate`, `browser_switch_tab`, `browser_open_tab`,
`browser_close_tab`, `browser_click`, `browser_type`, `browser_select`,
`browser_set_value`, `browser_check`, `browser_scroll`, `browser_wait_for`,
`browser_download`, `browser_get_file`.

`browser_read_table` returns JSON rows and CSV. `browser_download` and
`browser_get_file` fetch a URL with the page session and return at most 1.5
MB of base64. Screenshots are of the visible tab. Text results are truncated
to `servers.browser.max_chars` (default 12000).

A tool that names a URL, or that acts on a tab whose URL is outside the
allowlist, is refused. `browser_list_tabs` omits every other tab. Patterns
follow Chrome: `https://*/*` is every HTTPS URL, `*.example.it` is that host
and its subdomains, and `http://127.0.0.1:3000/*` keeps the port.

## Environment

| Variable | Purpose |
| --- | --- |
| `BROWSER_ALLOW_WRITE` | Catalog default for write tools. Default off |
| `BROWSER_TIMEOUT` | Seconds an MCP tool waits for the extension. Default `30` |
| `BROWSER_ALLOWED_ORIGINS` | Default allowlist when the instance field is empty. Default `https://*/*`. Comma-separated Chrome match patterns. The auth form overrides it |
| `BROWSER_ALLOW_EVAL` | Enable `browser_eval_readonly`. Default off. The expression runs in the page |
| `BROWSER_WS_HEARTBEAT` | Heartbeat interval in seconds. Default `15` |

## Build the zip

```bash
script/build-browser-extension
```

That writes `tmp/emcp-browser-extension.zip`. The Auth page serves the same
archive. Load the unzipped folder as an unpacked extension. Do not commit
`tmp/`.

## Chrome Web Store

The source in `servers/browser/extension/` is a Manifest V3 package:

- `manifest.json` declares `tabs`, `scripting`, `activeTab`, and `storage`.
  Host access is an optional permission requested from the popup for the
  allowlisted origins. There is no `<all_urls>` permission.
- Icons are `icons/icon16.png`, `icons/icon48.png`, and `icons/icon128.png`.
- No URL or token is compiled into the package.

To publish: zip that directory (the build script does this), upload it in the
Chrome Web Store developer dashboard, and submit the listing. The store review
should describe the extension as a connector to the operator's own eMCP
server. After install, pairing is still the QR code or the pasted payload
from the instance Auth page.

## Retention

Tool calls are recorded in `log/browser-<id>.log` with the tool name and
status. Argument values named `text`, `value`, `expression`, and `token` are
redacted. Page HTML, screenshots, and file bytes are not written to the log.
Dated logs are removed after `Settings.logs.retain_days` (default 30).
Pairing state lives in the instance credentials and
`storage/mcp/instances/<id>/`, which is gitignored.
