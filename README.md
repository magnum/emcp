# EmCP

EmCP is a self-hosted [Model Context Protocol](https://modelcontextprotocol.io/) host built on **Rails 8**, based on the [`railsapp`](../railsapp) template.

Operator UI uses **session login** (`User`). MCP clients authenticate with **ApiKey** Bearer tokens and/or per-server **OAuth 2.1** (PKCE). Integration code still lives under `servers/<code>/` as STI subclasses of `McpServer`.

> The previous Sinatra host is archived under [`legacy/`](legacy/) on this branch for reference while the port is validated. Do not merge to `main` until this branch is green.

## Quick start

```bash
cp .env.example .env   # or set vars below
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

### Production env (Kamal)

Keep only deploy-critical secrets in `.kamal/secrets` / `deploy.yml` (`RAILS_MASTER_KEY`, Google OmniAuth, `APP_HOST`).

Put the rest in a single file on the server volume (not in git):

```bash
# on the deploy host
install -m 600 /dev/stdin /data/emcp/storage/.env < .env   # from your machine via scp/ssh
```

That file is mounted at `/rails/storage/.env` and loaded at boot for web + worker. Existing Kamal/env values are not overridden.

### Required env

| Variable | Purpose |
| --- | --- |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Google Sign-In (OmniAuth). Redirect: `${APP_HOST}/auth/google_oauth2/callback` |
| `EMCP_PUBLIC_URL` | Public base URL (no trailing slash), used in MCP/OAuth metadata |
| `EMCP_USER1_PASSWORD` | Password for seeded operator `user1@emcp.local` (dev default: `emcp-dev-password`) |
| `API_KEY_HMAC_SECRET_KEY` | HMAC secret for ApiKey digests |

### Operator login

- Email: `user1@emcp.local`
- Password: `EMCP_USER1_PASSWORD` (or the development default)
- Integrations: `/servers` (signed-in home)
- Public landing: `/`
- Auth per instance: `/servers/<id>/auth`
- Google Sign-In callback: `https://emcp.m6i.it/auth/google_oauth2/callback`

### MCP clients

Each instance has its own endpoint (copy it from `/servers`):

```text
${EMCP_PUBLIC_URL}/servers/<type_code>/<id>/mcp
```

Claude, ChatGPT, Cursor, and similar tools are MCP **clients**. Several of them can attach to the **same** instance (same provider account and tools) as separate OAuth clients, or share one user API key. Use **separate instances** when you need isolated credentials (work vs personal, two Fatture companies, …).

**ApiKey (static Bearer)** — in console:

```ruby
User.find_by(email: "user1@emcp.local").api_key!
# => "tkn_usr_..."
```

Send `Authorization: Bearer tkn_usr_...`. The key authenticates as the instance owner.

**OAuth 2.1** — discovery (per instance):

- `/.well-known/oauth-authorization-server/servers/<type_code>/<id>`
- `/.well-known/oauth-protected-resource/servers/<type_code>/<id>/mcp`

## Architecture

- **Type** (`McpServerType`): catalog entry for an integration (`hey`, `fattureincloud`, …). Shared defaults live in `config/settings.yml` under `servers.<code>` (timeouts, max_chars, allow_write).
- **Instance** (`McpServer`): one row per user, with its own name, tags, credentials, and MCP URL. You can create many instances, including several of the same type.
- One instance = one provider account (one Basecamp, one Fatture company, …). Many AI clients can connect to that instance.
- `servers/<code>/server.rb` registers with `Emcp.register_integration(...)` and overrides tools/auth (STI on `McpServer`)
- Instance credentials: encrypted columns + `storage/mcp/instances/<id>/server.yml`
- MCP OAuth clients/tokens: AR tables (`mcp_oauth_*`), many clients per instance
- MCP activity logs: `log/<server_code>-<id>.log` (daily rotation). Retention: `Settings.logs.retain_days` (default 30). Override directory with `Settings.logs.directory`.

## Integrations

Same set as before, plus 1Password and WhatsApp: HEY, Basecamp, Fatture in Cloud, Google Workspace, Toggl Track, Bluesky, Twitter/X, TeslaMate, Home Assistant, 1Password, WhatsApp. See each `servers/*/README.md`.

## Tests

```bash
bin/rails test test/models/mcp_server_test.rb test/services/mcp_oauth_provider_test.rb test/controllers/mcp_servers
```

## Deploy notes

Prefer Kamal from the railsapp template (`config/deploy.yml`). Wire `API_KEY_HMAC_SECRET_KEY`, `EMCP_PUBLIC_URL`, and `EMCP_USER1_PASSWORD` into secrets. Keep TeslaMate/Postgres and CLI binaries available to the app container as needed.
