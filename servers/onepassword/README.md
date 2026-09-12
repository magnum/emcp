# 1Password

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for [1Password CLI](https://www.1password.dev/cli), authenticated
with a [service account token](https://www.1password.dev/service-accounts/use-with-1password-cli)
so the server does not need the 1Password desktop app.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/onepassword/mcp
```

Operator UI: `/servers/onepassword/auth`

## Credentials

1. On 1Password.com: **Developer → Service Accounts → Create**.
2. Grant only the vaults EmCP should use (`read_items`, and `write_items` if you enable writes).
3. Personal, Private, Employee, and the default Shared vault cannot be granted.
4. Save the token when it is shown (once), then paste it on `/servers/onepassword/auth`.

The token is stored as `OP_SERVICE_ACCOUNT_TOKEN`. EmCP unsets `OP_CONNECT_HOST` /
`OP_CONNECT_TOKEN` for `op` so a leftover Connect config cannot override it.
`OP_CONFIG_DIR` is created with mode `700` — `op` refuses a world-readable config directory.

## Environment

| Variable | Purpose |
| --- | --- |
| `OP_SERVICE_ACCOUNT_TOKEN` | Service account token (`ops_…`) |
| `OP_BIN` | Override binary path (default `op`) |
| `OP_TIMEOUT` | CLI timeout seconds (default `45`) |
| `OP_CONFIG_DIR` | Isolated CLI config dir (default `storage/mcp/onepassword/config`) |
| `ONEPASSWORD_ALLOW_WRITE` | Enable write tools |

## Tools

Read: whoami, ratelimit, vault list/get, item list/get, secret `op://` read, document list/get.  
Write (gated): vault create/delete, item create/edit/delete.

Prefer vault and item **IDs** — service accounts are rate-limited, and `op item` /
`op document` need `--vault` when more than one vault is visible.

## Files

- `server.rb` — MCP tools and auth form
- `onepassword_client.rb` — thin `op` wrapper
