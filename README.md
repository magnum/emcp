# EmCP

Self-hosted [Model Context Protocol](https://modelcontextprotocol.io/) host on **Rails 8** (Ruby 4.0.5, see `mise.toml`).

The operator UI uses a **session login** (`User`). MCP clients authenticate with an **ApiKey** Bearer token and/or per-instance **OAuth 2.1** (PKCE). Each integration is an STI subclass of `McpServer` under `servers/<code>/`.

## Quick start

You need Ruby 4.0.5 and `config/master.key`. The key is not in git (it decrypts `config/credentials.yml.enc`). Ask the repo owner for it and place it at `config/master.key` before booting.

```bash
cp .env.example .env
bundle install
bin/rails db:prepare
bin/rails db:seed
bin/dev
```

`bin/dev` starts the web server on port 3000, Solid Queue, and the Tailwind watcher. Open http://localhost:3000.

`EMCP_PUBLIC_URL` defaults to `http://localhost:3000` when unset. For OAuth callbacks that must match a public host, set it in `.env` with no trailing slash.

### Local login

- Email: `user1@emcp.local`
- Password: `EMCP_USER1_PASSWORD`, or `emcp-dev-password` in development
- After seed, the console prints a development ApiKey (`tkn_usr_…`) when the user has none
- Integrations: `/servers`
- Contexts (hubs that proxy other servers): `/contexts`
- Instance auth: `/servers/<id>/auth` (numeric instance id, from the servers or contexts list)
- Google Sign-In is optional. It appears only when `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` are set. Redirect: `${APP_HOST}/auth/google_oauth2/callback`

CLI-backed tools (HEY, Basecamp, Google Workspace, 1Password, Home Assistant) call binaries. The Docker image ships them. A local `bin/dev` process uses whatever is on `PATH` (`HEY_BIN`, `BASECAMP_BIN`, `OP_BIN`, `HASS_CLI_BIN`, and `gws`). WhatsApp’s Go bridge is built from `servers/whatsapp/bridge` or baked into the image.

### Environment

| Variable | Purpose |
| --- | --- |
| `EMCP_PUBLIC_URL` | Public base URL, no trailing slash. OAuth metadata and MCP URLs |
| `EMCP_USER1_PASSWORD` | Seeded operator password. Development default: `emcp-dev-password` |
| `API_KEY_HMAC_SECRET_KEY` | HMAC secret for ApiKey digests. Development falls back to a fixed dev secret |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Optional Google Sign-In |
| `APP_HOST` | Optional. Used as the public URL when `EMCP_PUBLIC_URL` is unset |
| `WEBHOOK_RETAIN` | Seconds to keep outbound webhook rows. Default `604800` (7 days). `PurgeWebhooksJob` runs daily |
| `BROWSER_ALLOW_WRITE` | Enable Browser write tools (click, type, navigate). Default off |
| `BROWSER_TIMEOUT` | Seconds to wait for the Chrome extension. Default `30` |
| `BROWSER_ALLOWED_ORIGINS` | Browser allowlist when the instance field is empty. Default `https://*/*`. Comma-separated Chrome match patterns |
| `BROWSER_ALLOW_EVAL` | Enable `browser_eval_readonly`. Default off |
| `BROWSER_WS_HEARTBEAT` | Seconds between extension heartbeats. Default `15`. A silent socket is treated as offline after three intervals |

Per-integration variables are in `.env.example` and `servers/<code>/README.md`. Prefer the auth form over putting provider tokens in `.env`.

## MCP clients

Copy the endpoint from `/servers`. It includes the type code and the instance id:

```text
${EMCP_PUBLIC_URL}/servers/<type_code>/<id>/mcp
```

A **Context** is one MCP URL that proxies a bundle of your other servers (house, work, a project). Copy it from `/contexts`:

```text
${EMCP_PUBLIC_URL}/context/<id>/mcp
```

Claude, ChatGPT, Cursor, and similar tools are MCP clients. Several of them can attach to the same instance. Use separate instances for isolated credentials (work vs personal, two Fatture companies). Point a client at a Context when it should see a whole bundle through one connector.

**ApiKey**

```ruby
User.find_by(email: "user1@emcp.local").api_key!
# => "tkn_usr_..."
```

Send `Authorization: Bearer tkn_usr_...`. The key authenticates as the instance owner.

**OAuth 2.1** discovery, per instance:

- `/.well-known/oauth-authorization-server/servers/<type_code>/<id>`
- `/.well-known/oauth-protected-resource/servers/<type_code>/<id>/mcp`

Per context:

- `/.well-known/oauth-authorization-server/context/<id>`
- `/.well-known/oauth-protected-resource/context/<id>/mcp`

Provider OAuth callbacks (Fatture in Cloud, X, …) are:

```text
${EMCP_PUBLIC_URL}/servers/<type_code>/<id>/oauth_callback
```

The auth form prints that URL. Register that exact string with the provider.

## Architecture

- **Type** (`McpServerType`): catalog entry (`hey`, `fattureincloud`, `context`, …). Shared defaults live in `config/settings.yml` under `servers.<code>`.
- **Instance** (`McpServer`): one row per user, with its own name, tags, credentials, and MCP URL. Many instances of the same type are allowed.
- **Context**: an instance of type `context`. Not seeded by `provision_defaults_for!`. Join table `context_memberships` (`active` pauses a member without removing it). Nested contexts are forbidden.
- One instance is one provider account. Many AI clients can connect to it.
- `servers/<code>/server.rb` registers with `Emcp.register_integration(...)`.
- Instance credentials: encrypted columns plus `storage/mcp/instances/<id>/` (`server.yml`, `oauth_token.json`). That directory is gitignored.
- MCP OAuth clients and tokens: `mcp_oauth_*` tables.
- Activity logs: `log/<server_code>-<id>.log`, kept for `Settings.logs.retain_days` (default 30).

## Integrations

HEY (CLI 1.6.0), Basecamp (CLI 0.11.0), Fatture in Cloud (API v2), Google Workspace (`gws` 0.22.5), Toggl Track (API v9), Bluesky, Twitter/X (API v2), TeslaMate, Home Assistant (`hass-cli`), 1Password (CLI 2.39.0), WhatsApp (`whatsmeow` bridge), Microsoft Graph (SharePoint sites), Shopify (Admin API, one store per instance), Browser (Chrome extension relay), Context (hub that proxies other instances). Details are in each `servers/*/README.md`.

## Contexts

The operator UI splits **Servers** (`/servers`) and **Contexts** (`/contexts`). The active tab is underlined.

Create a context, open it, attach the servers it should proxy. Pause a membership to keep it listed without exposing tools. Turn the context itself inactive to refuse proxied calls while MCP clients can still connect.

The hub does not flatten child catalogs. Clients call `context_list_servers`, then `context_get_server` / `context_list_tools`, then `context_call_tool` with the child tool name and arguments. Identify a proxied server by numeric id, instance id (`hey-12`), or type code when it is unique in that context. See `servers/context/README.md`.

## Tests

```bash
bin/rails test
```

## Deploy

Kamal config is `config/deploy.yml`. The image downloads the CLI binaries and builds the WhatsApp bridge. Production secrets (`RAILS_MASTER_KEY`, Google OmniAuth) come from `.kamal/secrets`. Other runtime env can live in `/data/emcp/storage/.env` on the host volume, loaded at boot and not overriding values already set by Kamal.

The footer (`vX.Y.Z · abc1234`) is baked into `VERSION` at image build (`GIT_COMMIT` / `GIT_TAG` from the current git HEAD and the highest `v*` tag). The image does not include `.git`. A new version number needs a new tag (`git tag v1.2.1`); the short SHA updates on every deploy.

```bash
install -m 600 /dev/stdin /data/emcp/storage/.env < .env
```
