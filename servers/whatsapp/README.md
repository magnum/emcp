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
| `WHATSAPP_ALLOW_WRITE` | Enable `whatsapp_send_message` and `whatsapp_set_owner_status` |
| `WHATSAPP_WEBHOOK_CHAT_HISTORY` | Default number of recent messages sent in `history`. Default `100`. The cache keeps up to 1000 per chat. A hook’s Messages history value replaces this |

## Incoming webhooks

The bridge posts each new live message to this instance:

```text
POST ${EMCP_PUBLIC_URL}/servers/<id>/inbound_messages
X-Bridge-Token: <bridge token>
```

The bundled bridge gets that URL when it starts. An external bridge must set `WHATSAPP_INBOUND_URL` to the same path and send the instance bridge token.

WhatsApp code decides whether to call. The HTTP call itself is the app-wide `Webhook` (`Webhookable#webhook!`, async `WebhookJob`). Other servers can use the same API.

Configure one or more hooks on the instance page. The secret is stored encrypted and is not shown again. The request sends it as `Authorization: Bearer <secret>` unless you change the header name.

| Option | Default | Meaning |
| --- | --- | --- |
| `owner_status` | `active` | `active` or `away`. Tool: `whatsapp_set_owner_status` |
| `respond_when` | `mention` | `never` sends nothing. `always` sends every message. `mention` sends direct chats and mentions. `word` sends only when `consider_words` matches |
| `consider_words` | `bot` | Comma-separated, case-insensitive, whole word. Used when `respond_when` is `word` |
| `history_limit` | env | Messages included in `history`, from 0 to 1000. Empty uses `WHATSAPP_WEBHOOK_CHAT_HISTORY` |

`respond_when` is the only send rule. A message that fails is not posted. The first decision for a `message_id` is kept, so reconnects and history sync do not send it twice.

The bridge does not notify for the initial history sync (`INITIAL_BOOTSTRAP`, `FULL`, and the non-message sync types). After that first connection, a later `RECENT` sync can notify messages that were not stored yet (caught up while the bridge was down). Live `events.Message` traffic is always eligible, including messages that arrive while another device reads them. Reactions, protocol/system messages, receipts, typing, and calls are not forwarded. Ephemeral and view-once messages are unwrapped and treated as normal text or media. Edits of a message already stored are not sent again.

Payload:

```json
{
  "event": "message.received",
  "instance": "whatsapp-12",
  "webhook_id": 1,
  "message_id": "ABC",
  "timestamp": "2026-10-03T12:00:00Z",
  "chat_jid": "393331234567@s.whatsapp.net",
  "chat_name": "Ada",
  "is_group": false,
  "sender_jid": "393331234567@s.whatsapp.net",
  "sender_phone": "393331234567",
  "sender_name": "Ada",
  "is_from_me": false,
  "type": "text",
  "text": "ciao",
  "quoted_message_id": null,
  "mentions_owner": true,
  "matched_words": [],
  "match_reason": "mention",
  "owner_status": "active",
  "media": null,
  "history": [
    {
      "message_id": "ABC",
      "timestamp": "2026-10-03T12:00:00Z",
      "text": "ciao"
    }
  ]
}
```

`match_reason` is `always`, `mention`, or `word`. `media` is `{ "mimetype", "filename" }` and does not include the file. `history` is the newest messages of that chat, oldest first, including this message. The count is the hook’s Messages history when set, otherwise `WHATSAPP_WEBHOOK_CHAT_HISTORY` (default 100). Every inbound message is cached, including ones that do not fire a webhook. Delivery is async, times out after 10 seconds, retries up to 3 times on network errors and HTTP 5xx, and does not retry HTTP 4xx. `Send test` on the instance page performs one synchronous call and shows the status code and response. `PurgeWebhooksJob` deletes the stored call (body, response, headers) after `WEBHOOK_RETAIN` seconds, default 7 days. The WhatsApp receipt that blocks a second send of the same message stays.

## Tools

Read: status, search contacts, list/get chats, list messages, message context,
last interaction.  
Write (gated): send text message, set owner status for webhooks.

Media send/download from the upstream Python MCP are not exposed yet; text
history still records when a message had media.

## Files

- `server.rb` — MCP tools and auth form
- `dispatch.rb` — whether an incoming message calls a webhook
- `chat_history.rb` — last messages per chat, in Solid Cache
- `hook.rb` — per-instance webhook settings
- `whatsapp_client.rb` — HTTP client for the Go bridge
- `bridge_process.rb` — starts/stops a per-instance bridge on localhost
- `bridge/` — Go WhatsApp Web companion (whatsmeow)
