# Credential-safe browser sessions

`ar-crawl session --secure-profile /absolute/path/profile.json` runs an isolated,
non-recording browser process. Requires Node **22.13+**, Playwright **1.48+** and
its installed Chromium. The normal `session` command retains its existing
shared-service and recording behavior. Install all three service JavaScript
files with the rebuilt CLI (`make dist-full` bundles them).

A trusted person/application supplies the profile; the model receives only
connection IDs. Keep the profile and any credential env file outside source
repositories, owned by the current user, with mode `0600` in a `0700` directory.
Symlink files, group/world permissions and files over 64 KiB are rejected.
An env file is plaintext; permissions do not isolate other processes running as
the same OS user. A credential provider backed by an OS keychain is preferable.

Example profile (selectors depend on the website):

```json
{
  "connections": [{
    "id": "school",
    "name": "School portal",
    "loginUrl": "https://school.example/login",
    "usernameSelector": "input[name=username]",
    "passwordSelector": "input[type=password]",
    "submitSelector": "button[type=submit]",
    "successSelector": "#account-home",
    "resourceOrigins": [],
    "credential": {
      "type": "env-file",
      "path": "/absolute/private/school.env",
      "usernameKey": "SCHOOL_USERNAME",
      "passwordKey": "SCHOOL_PASSWORD"
    }
  }]
}
```

The private env file contains `SCHOOL_USERNAME` and `SCHOOL_PASSWORD`. It is
parsed as data, never shell-sourced or copied into the process environment.
Enter credentials in your local editor, not in an agent conversation or shell
command arguments.

Session commands still use JSON lines:

```text
{"type":"login","connectionId":"school"}
state --full
{"type":"click","selector":"a[href='/notices']"}
state --actions
exit
```

Login navigates to the saved HTTPS URL, verifies the exact origin and unique
visible input fields, retrieves credentials, fills and submits the saved form,
and checks the configured success marker. Standard forms must use same-origin
POST. The success marker must be absent before login and visible afterwards,
with the password field no longer visible. A failed/unconfirmed login closes
the page and reports failure; it never asserts success from a click alone.
This version supports single-page forms. MFA, CAPTCHA, multi-page login and
cross-origin SSO require a different/manual sign-in flow. No existing browser
profile or saved cookies are imported. Sessions close at EOF, `exit`, or normal
termination, and are not persisted for later routines.

Supported commands: `help`, `state`, `state --full`, `state --actions`,
`state --forms`, `exit`, plus JSON actions `login`, `goto`, `click`, `fill`,
`selectOption`, `check`, `uncheck`, `press`, `scroll`, `waitForSelector`.
Keyboard actions require a selector and an allowed navigation key. Password
fields cannot be filled by ordinary agent actions. No JavaScript evaluation,
raw HTML, screenshots, clipboard shortcuts, downloads, cookie export, commit,
recording, tracing or arbitrary file writes are exposed.

Network policy is enforced in the browser driver, including redirect hops.
Navigation, forms and API requests remain on the login origin. Additional
`resourceOrigins` allow only GET static resources (scripts, styles, images,
fonts and media). Redirects cannot change the original request's origin;
POST-preserving navigation redirects (307/308) are rejected. Ordinary navigation
redirects become fresh navigations, so every hop is checked. WebSockets,
service workers and popups are blocked. Resources from unlisted hosts will not
load; explicitly add only hosts you trust. These restrictions may make some
sites incompatible.

The destination website and its allowed scripts necessarily receive the login
values: this is not protection against a compromised login website, malicious
same-origin scripts, an OS-level attacker, or a model misusing the account's
permitted actions. State output omits form values and redacts known credential
strings (including URL/base64 representations); errors never include underlying
Playwright diagnostics. Profiles must be trusted, not generated from page text.

## Credential-provider integration

Applications can supply this credential source instead of an env file:

```json
{"type":"broker","url":"http://127.0.0.1:PORT/","token":"RANDOM_PER_SESSION_CAPABILITY"}
```

The driver POSTs `{"id":"school"}` with an `Authorization: Bearer …` header
only after verifying the login page and fields. The provider returns a bounded
JSON object containing `username` and `password`. Redirects are forbidden and
requests time out. The provider should bind only to loopback, reject browser
Origin headers, validate the token and connection grant on every request,
limit calls, and expire when the run finishes. Neither its token nor the private
profile should be passed to the agent/model process. Naninunu uses this route
with macOS Keychain and explicit per-request/routine grants.

Run `npm run test:secure` in `playwright-service/` for browser and policy tests.
Tests use local HTTPS fixtures and headless Chrome; no real credentials or
external websites are involved.
