# Tessie

← [Back to project](https://github.com/magnum/emcp)

EmCP integration for [Tessie](https://www.tessie.com) vehicles, using the [Tessie API](https://developer.tessie.com). Reads use Tessie's cached vehicle state and do not wake the car. Commands wake it when it is asleep.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/tessie/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Environment

| Variable | Purpose |
| --- | --- |
| `TESSIE_API_TOKEN` | Required. Token from [dash.tessie.com/settings/api](https://dash.tessie.com/settings/api), sent as `Authorization: Bearer`. |
| `TESSIE_DEFAULT_VIN` | Optional. Used when a tool call omits `vin`. Otherwise the first vehicle from `GET /vehicles` is used. |
| `TESSIE_ALLOW_WRITE` | Type default is `false`. The instance checkbox `allow_write` gates command tools. |
| `TESSIE_TIMEOUT` | HTTP timeout seconds (default `45`). Wake uses at least 100 seconds. |

Distances requested from Tessie are kilometers, temperatures Celsius, and tire pressure bar, on the endpoints that accept those units. `GET /{vin}/state` has no unit parameter, so range in the summary is converted from miles.

## Read tools

| Tool | API |
| --- | --- |
| `tessie_list_vehicles` | `GET /vehicles` |
| `tessie_get_state` | `GET /{vin}/state?use_cache=true`. Compact summary, or the full JSON when `raw=true`. |
| `tessie_get_location` | `GET /{vin}/location` |
| `tessie_get_battery` | `GET /{vin}/battery` |
| `tessie_get_drives` | `GET /{vin}/drives` with `from`, `to`, and `limit` |
| `tessie_get_charges` | `GET /{vin}/charges` with `from`, `to`, and `limit` |
| `tessie_get_tire_pressure` | `GET /{vin}/tire_pressure?pressure_format=bar` |

Reads are cached in EmCP for 20 seconds. `from` and `to` accept ISO 8601 or a Unix timestamp.

## Command tools

These are registered even when writes are off. Calling one then returns `write method disabled`. Set **Allow write** on the instance to enable them.

Each command sends `wait_for_completion=true` and `max_attempts=3` (Tessie's retry parameter; the maximum is 3). If `GET /{vin}/status` is not `awake`, EmCP calls `POST /{vin}/wake` first.

| Tool | API |
| --- | --- |
| `tessie_lock` / `tessie_unlock` | `POST /{vin}/command/lock` and `unlock` |
| `tessie_climate_start` / `tessie_climate_stop` | `start_climate` / `stop_climate` |
| `tessie_set_temperature` | `set_temperatures?temperature=` (15–28 °C) |
| `tessie_charge_start` / `tessie_charge_stop` | `start_charging` / `stop_charging` |
| `tessie_set_charge_limit` | `set_charge_limit?percent=` (50–100) |
| `tessie_open_charge_port` / `tessie_close_charge_port` | `open_charge_port` / `close_charge_port` |
| `tessie_honk` / `tessie_flash_lights` | `honk` / `flash_lights` |
| `tessie_vent_windows` / `tessie_close_windows` | `vent_windows` / `close_windows` |
| `tessie_open_frunk` / `tessie_open_trunk` | `activate_front_trunk` / `activate_rear_trunk` |
| `tessie_sentry_on` / `tessie_sentry_off` | `enable_sentry` / `disable_sentry` |
| `tessie_share_destination` | `share?value=` |
| `tessie_wake` | `POST /{vin}/wake` |

A command returns `{ ok, command, vin, message, result }`.

HTTP 401 means the token is invalid. 408 or a timeout means the vehicle may be asleep. 429 and HTTP 5xx are retried up to 3 times with backoff. Logs record the method, path, and status only.

## Files

- `server.rb` — MCP tools, auth form
- `tessie_client.rb` — HTTPS client, cache, retries
- `state_summary.rb` — compact read payloads
