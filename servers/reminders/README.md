# Apple Reminders

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for iCloud Reminders over CalDAV. The host signs in with an Apple ID and an [app-specific password](https://support.apple.com/en-us/102654) and talks to `https://caldav.icloud.com`. No Mac and no Reminders app are involved, so this runs on the Linux server.

Apple does not publish a REST API for Reminders. CalDAV (`VTODO`, RFC 4791) is the remote protocol. Since iOS 13, reminder lists that were upgraded to the current format stay on Apple's newer store and are not returned here. If discovery finds zero lists, that limit is the usual reason.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/reminders/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Environment

| Variable | Purpose |
| --- | --- |
| `REMINDERS_APPLE_ID` | Apple Account email. |
| `REMINDERS_APP_PASSWORD` | App-specific password from [account.apple.com](https://account.apple.com). Not the account password. |
| `REMINDERS_DEFAULT_LIST` | Optional list name. `reminders_create` uses it when the call omits a list. |
| `REMINDERS_CALDAV_URL` | Optional. Defaults to `https://caldav.icloud.com/`. Discovery finds the account's `pXX-caldav.icloud.com` host. |
| `REMINDERS_ALLOW_WRITE` | Type default is `false`. The instance checkbox `allow_write` gates create, update, and delete. |
| `REMINDERS_TIMEOUT` | Per-request timeout in seconds (default `60`). |

The password is sent as CalDAV basic auth and is stored with the instance credentials. Revoke it at account.apple.com to cut access. It can reach the account's CalDAV data, not only Reminders.

## Priority

Apple's scale is the source of truth: `0` is none, `1-4` is high, `5` is medium, `6-9` is low. The names `none`, `high`, `medium`, and `low` write `0`, `1`, `5`, and `9`.

## Dates

Dates are ISO 8601. A value without a time is an all-day due date. A due filter is inclusive. Incomplete reminders match on the due date, completed reminders on the completion date. A reminder without that date is left out.

`url` is the VTODO `URL` property.

## Read tools

| Tool | What it returns |
| --- | --- |
| `reminders_lists` | Every VTODO list: id, name, color, account, default. Event calendars are skipped. |
| `reminders_list` | One list by `list_id` or `list_name`. `calendar_id` and `calendar_name` are aliases. |
| `reminders_default_list` | `REMINDERS_DEFAULT_LIST`, otherwise the list named Reminders, otherwise the first list. |
| `reminders_search_lists` | Lists whose name or account contains `query`. |
| `reminders_get_reminders` | Reminders filtered by list, `due_after`, `due_before`, `is_completed`, and `priority`. |
| `reminders_get` | One reminder by its CalDAV URL or UID. |
| `reminders_next` | The earliest incomplete reminder due now or later. |
| `reminders_search` | `reminders_get_reminders` plus a title/notes `query`. |

`limit` defaults to 200. `0` returns every match. The payload includes `total` and `truncated`.

## Write tools

These stay disabled until `allow_write` is on.

| Tool | What it changes |
| --- | --- |
| `reminders_create` | Title, notes, URL, due date, priority, completion, and list. |
| `reminders_update` | The same fields on an existing id. An empty `due_date` or `url` clears it. Alarms already on the reminder are kept. |
| `reminders_delete` | Deletes one reminder by id. |

The list container cannot be changed. A reminder stays in the list where it was created.
