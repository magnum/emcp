# Jethr

← [Back to project](https://github.com/magnum/emcp)

Read the employee list and one employee from a Jethr admin session that is already open in Chrome.

## MCP endpoint

```text
${EMCP_PUBLIC_URL}/servers/jethr/<id>/mcp
```

Operator UI: `/servers/<id>/auth`

## Credentials

Jethr does not issue a bearer token. The admin app at `https://admin.jethr.com` calls `https://backend.jethr.com` with the Chrome session cookie (`sessionid`, HttpOnly) and the `csrftoken` cookie. The session cookie is not readable from the page, so EmCP does not copy it.

1. Pair a Browser instance in the Chrome profile that is signed in to Jethr.
2. Turn on **Allow page JavaScript** for that browser instance.
3. Leave a tab open on `https://admin.jethr.com`.
4. On this instance, set `JETHR_COMPANY_ID` (the number in `#/112/...`) and, when you have more than one browser, `JETHR_BROWSER_SERVER_ID`.

The form stores those two ids. Sign in again in that Chrome window when the session expires.

## Tools

`jethr_employees` lists people in force (`contract_status=IN_FORCE`, the in-forza tab). Pass `status=all` for every employee. Each row is id, name, job title, work email, and contract dates.

`jethr_employee` reads `GET /api/v1/employees/<id>/`, the panoramica record.

## Files

- `jethr_client.rb` — finds the admin tab and runs the API fetch inside it
