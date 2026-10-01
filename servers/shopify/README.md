# Shopify

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for one Shopify store through the [GraphQL Admin API](https://shopify.dev/docs/api/admin-graphql/2026-07). Each instance is one store you can access. Add another instance for another store.

This is store management, not the [Shopify AI Toolkit](https://shopify.dev/docs/apps/build/ai-toolkit). That toolkit runs Shopify CLI on your machine. EmCP calls the Admin API from the host, with a token from the store install.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/shopify/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials

1. In the [Shopify Dev Dashboard](https://dev.shopify.com/dashboard), create an app and copy the client ID and client secret.
2. Allowed redirection URL:

   ```text
   ${EMCP_PUBLIC_URL}/servers/shopify/<id>/oauth_callback
   ```

3. On the auth form, set the store domain (`your-store.myshopify.com`), client ID, and secret, then choose **Retrieve OAuth token** and approve the app on that store.
4. EmCP stores the expiring offline token, including `refresh_token`, at `storage/mcp/instances/<id>/oauth_token.json` and refreshes it.

## Environment

| Variable | Purpose |
| --- | --- |
| `SHOPIFY_SHOP` | `*.myshopify.com` domain |
| `SHOPIFY_CLIENT_ID` | App client ID |
| `SHOPIFY_CLIENT_SECRET` | App client secret |
| `SHOPIFY_TOKEN` | Admin API access token |
| `SHOPIFY_REFRESH_TOKEN` | Refresh token |
| `SHOPIFY_OAUTH_SCOPES` | Comma-separated override |
| `SHOPIFY_API_VERSION` | Admin API version (default `2026-07`) |
| `SHOPIFY_ALLOW_WRITE` | Allow GraphQL mutations |
| `SHOPIFY_TIMEOUT` | HTTP timeout seconds (default `30`) |

Default read scopes: `read_products`, `read_orders`, `read_inventory`, `read_locations`, `read_content`. With writes enabled, EmCP also requests `write_products`, `write_orders`, `write_inventory`, `write_content`. Turn on **Allow write** for the instance before Retrieve OAuth token, then approve the app again if the scopes change.

## Tools

`shopify_shop`, `shopify_products`, `shopify_orders`, `shopify_locations`, and `shopify_graphql` for any other Admin API operation. Mutations through `shopify_graphql` need `SHOPIFY_ALLOW_WRITE=true`.

## References

- [Authorization code grant](https://shopify.dev/docs/apps/build/authentication-authorization/get-access-tokens/auth-code-grant)
- [GraphQL Admin API](https://shopify.dev/docs/api/admin-graphql)
