# Jethr

← [Back to project](https://github.com/magnum/emcp)

Read employees, payroll cycles, and company reports from the Jethr API after a login.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/jethr/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials

The admin login is `POST https://backend.jethr.com/api/v1/auth/login/` with email and password. The response sets the `sessionid` cookie and the `csrftoken` cookie. EmCP stores both, plus a bearer token when the JSON body includes one, and sends them on later calls.

1. On `/servers/<id>/auth`, enter the Jethr email, password, and company id (`112` in `#/112/...`). Leave the security code blank and save.
2. Jethr sends a 6-character code by email. Paste it into **Codice di sicurezza** and save again. That calls `POST /api/v1/auth/validate_mfa_otp/`.
3. Leave the password blank on a later save to keep the current one.

When a later call returns 401 or 403, EmCP signs in again. If a code is required, save that code on the auth page.

## Tools

`jethr_employees` lists people in force (`contract_status=IN_FORCE`, the in-forza tab). Pass `status=all` for every employee. Each row is id, name, job title, work email, and contract dates.

`jethr_employee` reads `GET /api/v1/employees/<id>/`, the panoramica record.

`jethr_payrolls` lists payroll cycles (`GET /api/v1/payrolls/?company=<id>&expand_provisional=true`), the cedolini page.

`jethr_payroll` reads one month. `9-2026` calls `GET /api/v1/payrolls/get_by_year_monthly_pay/<company>/2026/9/` and the payslips of that cycle.

`jethr_report` reads one section for a month. Omit year and month to use the latest period from `monthly_reports/periods`.

| section | Admin path |
| --- | --- |
| `personale` | `#/<company>/report/personale` |
| `presenze-assenze` | `#/<company>/report/presenze-assenze` |
| `rimborsi-spese` | `#/<company>/report/rimborsi-spese` |
| `costo-aziendale` | `#/<company>/report/costo-aziendale` |
| `trasparenza-retributiva` | `#/<company>/report/trasparenza-retributiva` |
| `tfr-azienda` | `#/<company>/report/tfr-azienda` |

## Files

- `jethr_client.rb` — finds the admin tab and runs the API fetch inside it
