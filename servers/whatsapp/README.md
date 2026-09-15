# WhatsApp

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for a **personal WhatsApp account**, based on
[lharries/whatsapp-mcp](https://github.com/lharries/whatsapp-mcp) and
[whatsmeow](https://github.com/tulir/whatsmeow). EmCP talks to a small Go
bridge over HTTP; the bridge keeps the WhatsApp Web session and a local
SQLite history.

This is unofficial WhatsApp Web multi-device access, not Meta’s Cloud API.
WhatsApp can drop linked devices. Use it on a host you control.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/whatsapp/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Pair an account

1. Build the bridge once (dev) or rely on the binary baked into the Docker image:

   ```bash
   cd servers/whatsapp/bridge
   go build -o whatsapp-bridge .
   ```

2. Open the instance Auth page. Leave **Bridge URL** blank.
3. Click **Start pairing**. Scan the QR code in WhatsApp → Settings → Linked devices.
4. After the first link, later reconnects reuse the session under
   `storage/mcp/instances/<id>/whatsapp/` and should not need a new QR
   unless WhatsApp logged the device out.

Optional: run the bridge yourself and paste `http://127.0.0.1:8080` as the
bridge URL. The HTTP API is a superset of the original lharries send endpoint
(`POST /api/send`) plus status, chats, contacts, and messages.

## Environment

| Variable | Purpose |
| --- | --- |
| `WHATSAPP_BRIDGE_URL` | External bridge base URL. Empty = spawn the bundled binary |
| `WHATSAPP_BRIDGE_TOKEN` | Shared secret (`X-Bridge-Token`). Auto-generated for the bundled bridge |
| `WHATSAPP_BRIDGE_BIN` | Path to the Go binary (default `whatsapp-bridge` on `PATH`, or `servers/whatsapp/bridge/whatsapp-bridge`) |
| `WHATSAPP_TIMEOUT` | HTTP timeout seconds (default `30`) |
| `WHATSAPP_ALLOW_WRITE` | Enable `whatsapp_send_message` |

## Tools

Read: status, search contacts, list/get chats, list messages, message context,
last interaction.  
Write (gated): send text message.

Media send/download from the upstream Python MCP are not exposed yet; text
history still records when a message had media.

## Files

- `server.rb` — MCP tools and auth form
- `whatsapp_client.rb` — HTTP client for the Go bridge
- `bridge_process.rb` — starts/stops a per-instance bridge on localhost
- `bridge/` — Go WhatsApp Web companion (whatsmeow)
