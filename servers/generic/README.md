# Generic MCP

← [Back to project](https://github.com/magnum/emcp)

EmCP proxy for a remote MCP server. The instance speaks MCP to the URL you configure and republishes that server's tools, so a [Context](../context/README.md) can forward them with the other servers in the bundle.

The first intended endpoint is `https://wrks.it/mcp`.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/generic/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Authentication

Only token / API key for now.

| Choice | What it does |
| --- | --- |
| Authentication | `token`. Further schemes can be added later. |
| Send token | `header` or `query`. |
| Token key | Header name, or query parameter name. |

A blank key means `Authorization` for a header and `api_key` for a query string. The `Authorization` header is sent as `Bearer <token>` unless the token already starts with `Bearer`. Any other header name sends the raw token. The query string is appended to the MCP URL.

Remote tools are marked as writes. They stay disabled until **Allow write** is on for this instance, because the proxy cannot tell which remote tools only read. The Context that proxies this instance also has to allow writes.

## Environment

| Variable | Purpose |
| --- | --- |
| `GENERIC_URL` | Remote MCP endpoint, for example `https://wrks.it/mcp`. |
| `GENERIC_AUTH_TYPE` | `token`. |
| `GENERIC_TOKEN_IN` | `header` or `query`. |
| `GENERIC_TOKEN_KEY` | Header name or query parameter. |
| `GENERIC_TOKEN` | The token or API key. |
| `GENERIC_ALLOW_WRITE` | Type default is `false`. The instance checkbox gates the forwarded tools. |
| `GENERIC_TIMEOUT` | HTTP timeout in seconds (default `30`). |

## Order

`ord` is an integer on every MCP server, default `0`. This type uses `-1`, so Generic is the first entry in the server-type select and in the Context "Add a server" select.
