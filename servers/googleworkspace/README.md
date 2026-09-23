# Google Workspace

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for Google Docs, Sheets, Drive, and the rest of Workspace APIs exposed by the community [`googleworkspace/cli`](https://github.com/googleworkspace/cli) (`gws`). Typed tools cover common Docs/Sheets/Drive flows; Discovery-backed tools reach everything else.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/googleworkspace/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials

Prefer a durable refresh-token export (not a short-lived access token):

```bash
gws auth setup    # once, Google Cloud project + APIs
gws auth login
gws auth status
gws auth export --unmasked
```

Paste the exported JSON into `/servers/<id>/auth`. Leave the short-lived access token field empty: `GOOGLE_WORKSPACE_CLI_TOKEN` overrides the credentials file and expires quickly.

If the Google Cloud OAuth consent screen is still in **Testing**, Google expires the refresh token after **7 days** and EmCP will show Not authenticated again. Publish the app (Publishing status: In production) for a durable token. Daily refresh keeps a *published* token from going idle (6 months); it does not extend Testing tokens.

Set `GOOGLE_WORKSPACE_PROJECT_ID` for quota / billing attribution (often missing from the export).

Source of truth is the encrypted `mcp_servers.credentials` column. EmCP materializes `credentials.json` and `client_secret.json` under `storage/mcp/instances/<id>/gws/` at mode `0600` (directory `0700`) so `gws` can run. Those files are not the long-term store. A leftover `instances/<id>/credentials.json` from the type→instance migration is imported into the encrypted column and removed.

`ServerAuthTokenRefreshJob` (every 90 minutes) plus hourly `EnsureServiceTokenRefreshJob` refresh the access token and persist the new payload back into the encrypted column. Testing-status Google apps still die after 7 days; publish the OAuth client.

## Environment

| Variable | Purpose |
| --- | --- |
| `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` | Path to credentials JSON (set by the auth form) |
| `GOOGLE_WORKSPACE_CLI_TOKEN` | Discouraged short-lived access token |
| `GOOGLE_WORKSPACE_PROJECT_ID` | Cloud project ID |
| `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` | Forced per instance to `storage/mcp/instances/<id>/gws` |
| `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND` | `file` in Docker |
| `GOOGLEWORKSPACE_ALLOW_WRITE` | Enable write tools |
| `GOOGLEWORKSPACE_TIMEOUT` | CLI timeout seconds (default `60`) |

## Tools

About **22** tools, including:

- Typed Docs / Sheets / Drive helpers (Drive file tools default to shared-drive-friendly flags: `supportsAllDrives`, etc.)
- `googleworkspace_doc_batch_update` — Docs `batchUpdate` as **direct edits** only (`writeControl` supports revision IDs, not suggestion mode)
- Drive comments — `googleworkspace_drive_comments_list`, `googleworkspace_drive_comment_get`, `googleworkspace_drive_comment_create`, `googleworkspace_drive_comment_reply` (reply can `resolve` / `reopen`)
- `googleworkspace_discover` / `googleworkspace_schema`
- `googleworkspace_api_read` — read-ish Discovery methods
- `googleworkspace_api_call` — any Discovery method (`write: true`)

### Comments vs direct edits

The public Docs API has **no suggestion/review write mode** (`writeControl` only has `targetRevisionId` / `requiredRevisionId`). For review notes without rewriting the document, use Drive comments.

| Goal | Tool |
| --- | --- |
| Leave a review comment on a Doc/file | `googleworkspace_drive_comment_create` |
| Reply / resolve a comment | `googleworkspace_drive_comment_reply` |
| Change document content | `googleworkspace_doc_batch_update` (direct edit) |

Optional `anchor_line` / `quoted_text` / `anchor` on create are best-effort. Google Workspace editor apps treat API-defined anchors as **unanchored** in the UI (comments still appear under All Comments). True paragraph pin-to-text like the Docs UI is not fully available via the Drive Comments API.

`gws` builds its command tree from Google Discovery documents, so newly published methods can be used without changing EmCP. The CLI is community-driven and is not an officially supported Google product.

## Files

- `server.rb` — MCP tools and auth form
- `googleworkspace_client.rb` — `gws` CLI wrapper
