# Basecamp

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for [Basecamp](https://basecamp.com), backed by the official [`basecamp/basecamp-cli`](https://github.com/basecamp/basecamp-cli) **v0.11.0**. Also exposes the `basecamp://skill` resource.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/basecamp/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials (recommended: CLI credentials file)

Importing `credentials.json` lets the Basecamp CLI refresh OAuth tokens on the server. EmCP runs a weekly `ServerAuthTokenRefreshJob` that calls `refresh_service_token!` (CLI `me` + sync access token). There is **no** separate job class under `servers/basecamp/` — provider logic lives on the server model, same pattern as Twitter/Google.

1. On a trusted machine: `BASECAMP_NO_KEYRING=1 basecamp auth login`
2. Copy `~/.config/basecamp/credentials.json` into the auth form (or scp it to the server CLI path under `storage/mcp/basecamp/home/.config/basecamp/`).
3. Set the numeric **account ID** (`https://3.basecamp.com/<account_id>/…` or `basecamp accounts list`).
4. Save credentials on `/servers/<id>/auth`.

**Fallback:** paste only `basecamp auth token --quiet` — works until the access token expires (~2 weeks), with no background refresh.

## Environment

| Variable | Purpose |
| --- | --- |
| `BASECAMP_TOKEN` | Access token (optional when credentials.json is present; synced after CLI refresh) |
| `BASECAMP_ACCOUNT_ID` | Default account ID |
| `BASECAMP_ALLOW_WRITE` | Enable write tools |
| `BASECAMP_TIMEOUT` | CLI timeout seconds (default `30`) |
| `BASECAMP_NO_KEYRING` | Forced `1` for EmCP CLI invocations (file-backed credentials) |

## Project webhooks

On the server page, **Link a project** lists Basecamp projects. Linking one runs `basecamp webhooks create` with this instance’s URL (`/servers/<id>/basecamp_events/<token>`) for `Comment` and `Message`. Unlinking deletes that Basecamp webhook. Campfire and pings are not webhook types.

**Webhooks** on the same page are the outbound URLs. EmCP forwards each accepted event as JSON:

```json
{
  "event": "basecamp.event",
  "instance": "basecamp-<id>",
  "project_id": "2085958498",
  "project_name": "The Leto Laptop",
  "kind": "comment_created",
  "basecamp": { }
}
```

`basecamp` is the payload Basecamp posted. A mention is a `<bc-attachment sgid="…">` inside `basecamp.recording.content`; the sgid contains `gid://bc3/Person/<id>`. Basecamp does not filter by person, so the receiver decides. The secret is sent as `Bearer` on the configured header. Delivery is async and a repeated Basecamp event id is posted once per webhook.

## Tools

About **38** tools (projects, todos, cards, messages, comments, chat, files, schedule, search, people, notifications, and more). Mutations are gated by `BASECAMP_ALLOW_WRITE`.

## Files

- `server.rb` — MCP tools, auth form, `refresh_service_token!`
- `basecamp_client.rb` — thin CLI wrapper
- `skills/basecamp/SKILL.md` — vendored agent skill
