# Microsoft Graph

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for the [Microsoft Graph API](https://learn.microsoft.com/en-us/graph/use-the-api) v1.0, focused on reading and updating a SharePoint site (site properties, lists, list items, and document libraries).

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/microsoftgraph/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials

1. Register a confidential app in Microsoft Entra. Redirect URI:

   ```text
   ${EMCP_PUBLIC_URL}/servers/microsoftgraph/<id>/oauth_callback
   ```

2. Delegated permissions: `offline_access`, `User.Read`, `Sites.Read.All`. Add `Sites.ReadWrite.All` to edit a site, then grant admin consent.
3. Paste the tenant ID, application ID, and client secret in `/servers/<id>/auth`, then choose **Retrieve OAuth token**.
4. EmCP stores the token response, including `refresh_token`, at `storage/mcp/instances/<id>/oauth_token.json`. Access tokens last about an hour and are refreshed automatically.

Optional defaults: `MICROSOFTGRAPH_SITE_HOSTNAME` (`contoso.sharepoint.com`), `MICROSOFTGRAPH_SITE_PATH` (`sites/Marketing`), or `MICROSOFTGRAPH_SITE_ID`.

## Environment

| Variable | Purpose |
| --- | --- |
| `MICROSOFTGRAPH_TENANT_ID` | Directory tenant. Blank uses `organizations` |
| `MICROSOFTGRAPH_CLIENT_ID` | Entra application ID |
| `MICROSOFTGRAPH_CLIENT_SECRET` | Entra client secret |
| `MICROSOFTGRAPH_TOKEN` | Access token |
| `MICROSOFTGRAPH_REFRESH_TOKEN` | Refresh token |
| `MICROSOFTGRAPH_SITE_HOSTNAME` | Default SharePoint host |
| `MICROSOFTGRAPH_SITE_PATH` | Default site path, no leading slash |
| `MICROSOFTGRAPH_SITE_ID` | Default Graph site id |
| `MICROSOFTGRAPH_OAUTH_SCOPES` | Override scopes (space-separated) |
| `MICROSOFTGRAPH_ALLOW_WRITE` | Enable site, list, and item mutations |
| `MICROSOFTGRAPH_TIMEOUT` | HTTP timeout seconds (default `30`) |

Writes need both `Sites.ReadWrite.All` on the token and `MICROSOFTGRAPH_ALLOW_WRITE=true`.

## Tools

`microsoftgraph_me`, `microsoftgraph_sites_search`, `microsoftgraph_site`, `microsoftgraph_site_update`, list and list-item tools, `microsoftgraph_drives`, `microsoftgraph_drive_children`, and `microsoftgraph_request` for any other Graph v1.0 path. Mutations are write tools. `microsoftgraph_request` allows GET always; other methods follow the write gate.

## References

- [Use the Microsoft Graph API](https://learn.microsoft.com/en-us/graph/use-the-api)
- [Update a site](https://learn.microsoft.com/en-us/graph/api/site-update)
- [Working with SharePoint sites in Microsoft Graph](https://learn.microsoft.com/en-us/graph/api/resources/sharepoint)
