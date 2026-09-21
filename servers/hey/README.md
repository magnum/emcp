# HEY

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for [HEY](https://hey.com) email and related tools, backed by the official [`basecamp/hey-cli`](https://github.com/basecamp/hey-cli) **v1.6.0**. Also exposes the `hey://skill` resource (official CLI agent skill plus EmCP tool mapping).

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/hey/mcp
```

Operator UI: `/servers/hey/auth`

## Credentials

1. On a machine with a browser: `hey auth login` (or your usual HEY CLI login).
2. Copy the token: `hey auth token --quiet`
3. Paste it into `/servers/hey/auth` (EmCP Basic Auth already covers the operator).

Credentials are stored via the HEY CLI config volume (`./data/cli/hey` in Docker).

## Environment

| Variable | Purpose |
| --- | --- |
| `HEY_ALLOW_WRITE` | Enable write tools (`true` / `false`) |
| `HEY_TIMEOUT` | CLI timeout seconds (default `60`) |
| `HEY_NO_KEYRING` | Set in the image (`1`) so the CLI uses file storage in Docker |
| `HEY_NONINTERACTIVE` | Set by the client (`1`) so the CLI never prompts |

## Tools

The catalog follows hey-cli's noun-first commands: boxes, labels, collections, workflows, clips, snippets, search, contacts, The Screener, threads, drafts, calendars/events, todos, habits, time tracking, and journal. Mutations are `write: true` and gated by `HEY_ALLOW_WRITE`.

For `hey_compose` / `hey_reply` / `hey_forward`, prefer the `paragraphs` array (Markdown, one idea per item). The CLI converts Markdown to HEY rich text. Use `message_html` or `as_html` only for raw HTML. `draft: true` saves instead of sending. `from` on compose/draft edit picks a sender from `hey_account_senders`.

Use box item `id` for seen/move/label/trash. Use `topic_id` for thread read/reply/forward/share.

`hey_recordings` remains as a deprecated alias of `hey_events`.

## Files

- `server.rb` — MCP tools and auth form
- `hey_client.rb` — thin CLI wrapper
- `skills/hey/SKILL.md` — vendored agent skill
