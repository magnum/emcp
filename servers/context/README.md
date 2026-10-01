# Context

← [Back to project](https://github.com/magnum/emcp)

A Context is a hub: one MCP URL that proxies a bundle of your other EmCP servers (house, work, a project). MCP clients configure this connector instead of attaching HEY, Home Assistant, TeslaMate, and the rest one by one.

It is an `McpServer` of type `context`. It is **not** provisioned with the default catalog. Nested contexts are not allowed; only proxyable (non-context) instances of the same user can be members.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/context/<id>/mcp
```

Operator UI: `/contexts` (create), then `/servers/<id>` (memberships). Auth for MCP clients is the usual EmCP OAuth — there is no third-party login.

OAuth 2.1 discovery:

- `/.well-known/oauth-authorization-server/context/<id>`
- `/.well-known/oauth-protected-resource/context/<id>/mcp`

## Memberships

Each row in `context_memberships` links the hub to one server.

- **Active** membership: tools may be listed and called.
- **Paused** membership: still listed by `context_list_servers`; `context_call_tool` is refused.
- **Inactive** context (`mcp_servers.active`): clients can still connect; proxied calls are refused.

Write tools on a child honor the **context** `allow_write` flag.

## Tools

The catalog is four hub tools. Child tools are not flattened into this catalog.

| Tool | Role |
| --- | --- |
| `context_list_servers` | Proxied servers (id, instance, auth/noauth, active, name) |
| `context_get_server` | Details for one member, including tool count |
| `context_list_tools` | Tool catalog of one member |
| `context_call_tool` | Run a child tool (`server`, `tool`, `arguments`) |

`server` may be the numeric id, the instance id (`hey-12`), the type code when unique in this context, or the member name.

Typical flow: `context_list_servers` → `context_list_tools` → `context_call_tool`.

## Files

- `server.rb` — hub tools, `/context/:id` issuer, membership lookup
- `app/models/context_membership.rb` — join validations and `proxied_snapshot`
- `app/controllers/contexts_controller.rb` — `/contexts` index/new/create
- `app/controllers/mcp_servers/context_memberships_controller.rb` — add / pause / remove
