# Telegram

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for a **personal Telegram account** over MTProto
([gotd](https://github.com/gotd/td)), not the Bot API. EmCP talks to a small
Go bridge over HTTP. The bridge keeps an encrypted session for this instance.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/telegram/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

A context can include the instance like any other catalog server.

## Link an account

1. Build the bridge once (dev) or rely on the binary baked into the Docker image:

   ```bash
   cd servers/telegram/bridge
   go build -o telegram-bridge .
   ```

2. At [my.telegram.org](https://my.telegram.org) open API development tools and
   copy **api_id** and **api_hash**.
3. On the instance Auth page, enter those values and the phone number
   (country code, digits only, no `+`). Leave **Bridge URL** blank.
4. Click **Start linking**. Telegram sends a login code to that phone.
5. Enter the code and click **Submit code**. If the account has a cloud
   password, the page asks for it: enter it and click **Submit password**.
6. Later reconnects reuse the session under
   `storage/mcp/instances/<id>/telegram/session.bin`. The file is AES-GCM
   ciphertext. The key is `TELEGRAM_SESSION_KEY` in the instance credentials,
   which are encrypted at rest. The login code and the 2FA password are not
   stored.

Optional: run the bridge yourself and paste its base URL. Send
`X-Bridge-Token` on every `/api/*` call.

Reading chats and messages does **not** call `messages.readHistory` or
`channels.readHistory`. There is no tool that marks a chat as read.

## Environment

| Variable | Purpose |
| --- | --- |
| `TELEGRAM_API_ID` | api_id from my.telegram.org |
| `TELEGRAM_API_HASH` | api_hash from my.telegram.org |
| `TELEGRAM_PHONE` | Account phone, digits only |
| `TELEGRAM_SESSION_KEY` | 32-byte hex key for the session file. Generated on first link |
| `TELEGRAM_BRIDGE_URL` | External bridge base URL. Empty = spawn the bundled binary |
| `TELEGRAM_BRIDGE_TOKEN` | Shared secret (`X-Bridge-Token`). Auto-generated for the bundled bridge |
| `TELEGRAM_BRIDGE_BIN` | Path to the Go binary (default `telegram-bridge` on `PATH`, or `servers/telegram/bridge/telegram-bridge`) |
| `TELEGRAM_TIMEOUT` | HTTP timeout seconds (default `30`) |
| `TELEGRAM_ALLOW_WRITE` | Catalog default for `telegram_send_message` and `telegram_set_owner_status` |

`FLOOD_WAIT` is retried with the delay Telegram returns, up to three times and
30 seconds per wait. A longer wait is returned as an error that includes
Telegram’s message, for example `Telegram FloodWait: retry after 120 seconds. FLOOD_WAIT_120`.

## Incoming webhooks

The bridge posts each new live message to:

```text
POST ${EMCP_PUBLIC_URL}/servers/<id>/inbound_messages
X-Bridge-Token: <bridge token>
```

Webhooks are **off** until Enabled is ticked on the server page. Configure one
or more hooks there. The secret is stored encrypted and is not shown again.

| Option | Default | Meaning |
| --- | --- | --- |
| Enabled | off | Nothing is sent until this is on |
| Chat ids | empty | Whitelist of numeric chat ids. Empty allows every chat that matches the types |
| Chat types | private | `private`, `group`, and/or `channel` |
| Mentions only | off | In groups and channels, send only when the message mentions this account. Private chats are unchanged |
| Ignore muted | on | Skip chats Telegram has muted |
| Ignore channels | on | Skip channels even if the channel type is ticked |
| Owner status | Always | `Only when owner is away` sends only while `telegram_set_owner_status` is `away` |
| Aggregate every N minutes | 5 | One event per chat per window, with the messages collected in that window. `0` sends each message immediately |

Payload:

```json
{
  "event": "messages.received",
  "instance": "telegram-12",
  "webhook_id": 1,
  "chat_id": "123456",
  "chat_title": "Ada",
  "chat_type": "private",
  "owner_status": "away",
  "messages": [
    {
      "message_id": "99",
      "timestamp": "2026-10-04T15:00:00Z",
      "sender_id": "42",
      "sender_name": "Ada",
      "text": "ciao",
      "mentions_owner": false
    }
  ]
}
```

Timestamps are RFC3339 UTC. Messages sent by the linked account are not forwarded.

## Tools

Read: `telegram_status`, `telegram_search_contacts`, `telegram_list_chats`,
`telegram_get_chat`, `telegram_list_messages`, `telegram_get_message_context`,
`telegram_get_last_interaction`, `telegram_list_unread`.

Write (gated by allow_write): `telegram_send_message`, `telegram_set_owner_status`.

`telegram_send_message` takes `recipient` (`@username`, phone, or numeric
`chat_id`), `message`, and optional `reply_to_message_id`.

## Files

- `server.rb` — MCP tools and the linking form
- `telegram_client.rb` — HTTP client, FloodWait retry, RFC3339 timestamps
- `bridge_process.rb` — starts and stops the per-instance bridge
- `dispatch.rb` — whether an incoming message calls a webhook
- `hook.rb` — per-instance webhook settings
- `aggregator.rb` — one event per chat per debounce window
- `bridge/` — Go MTProto client (gotd)
