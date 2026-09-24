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
`state --forms`, `exit`, plus JSON actions `login`, `discoverFields`, `fillSecret`, `goto`, `click`, `fill`,
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

## Named sensitive fields

Connections can also grant individual sensitive fields, such as a card number,
account number or private identifier. Add `sensitiveFields` to the connection in
its trusted profile:

```json
{
  "sensitiveFields": [{
    "id": "payment-card-number",
    "url": "https://school.example/checkout",
    "selector": "input[name=cardNumber]",
    "source": {
      "type": "env-file",
      "path": "/absolute/private/payment.env",
      "key": "CARD_NUMBER"
    }
  }]
}
```

Only the field ID goes to the model. After logging in and navigating to the
checkout page, the agent sends:

```json
{"type":"fillSecret","fieldId":"payment-card-number"}
```

The command accepts no value, selector, source path or destination override.
The saved URL must match the current page exactly, including its query string,
and belong to the connection's origin. The driver verifies a unique, visible,
writable text-like input or textarea and, if associated with a form, a
same-origin POST action. It checks again after retrieving the value. Failed
validation or filling closes the page. Unknown IDs and command overrides are
rejected before any value is read.

The source can instead be an authenticated loopback broker with the same
`type`, `url` and `token` format described above. For a sensitive field the
request body is `{"id":"school","fieldId":"payment-card-number"}` and the
response is `{"value":"..."}`. Providers must independently authorize both
IDs on every request. A broker can supply a transient value without writing it
to an env file. The existing Naninunu login broker does not yet implement this
field protocol; its settings UI currently saves login credentials only.

This first version is **fill-only**. Once a sensitive value is filled, the
session allows further granted `fillSecret` commands, fixed status output,
`help`, `exit`, or a fresh `login` that destroys the previous browser context.
Other actions, including clicks, navigation and keypresses, are blocked. There
is no payment-submission or approval command. Page content is withheld because
the website could echo a formatted/partial value that exact-string redaction
would miss. Ordinary login-only sessions retain their existing behavior.

Filling dispatches browser input events: the approved website and its scripts
receive the value immediately and could send it or take actions themselves.
The action restriction is not a guarantee against automatic submission by the
website. Use only trusted destinations. Cross-origin payment-provider frames
and select controls are not supported by this version. No real card data is
needed in tests; the browser fixture uses a synthetic number.

### Semantic field matching

A grant can use a `semanticType` instead of a website-specific `selector`:

```json
{
  "id": "personal-card-number",
  "semanticType": "payment.card.number",
  "url": "https://school.example/checkout",
  "source": {
    "type": "env-file",
    "path": "/absolute/private/payment.env",
    "key": "CARD_NUMBER"
  }
}
```

These are three separate concepts: `semanticType` describes what a value means,
`id` identifies the granted private value, and discovery identifies the website
control. Matching a control does not grant access to any additional secret or
website. The command still references the trusted grant ID:

```text
{"type":"discoverFields"}
{"type":"fillSecret","fieldId":"personal-card-number"}
```

`discoverFields` reports only each grant's ID, semantic type and `matched` or
`needs-configuration` status. It never calls a secret provider, reads input
values or returns page-derived labels. A match is a discovery result, not proof
that the form is safe: filling separately validates the URL and form. Discovery
is unavailable after sensitive filling, like other page output.

Matching uses [HTML autocomplete field names](https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#autofill)
and conservative English label matching (associated labels, ARIA labels,
placeholders, names and IDs). Explicit autocomplete types override label hints;
contradictory types do not match. Hidden, disabled, read-only and incompatible
input types are excluded. Exactly one candidate is required; ambiguity never
picks the first input. Missing or ambiguous matches require updating the trusted
profile, optionally with a selector override. Labels are hints from the trusted
destination, not an independent security boundary.

| Semantic type | Autocomplete field |
| --- | --- |
| `payment.card.number` | `cc-number` |
| `payment.card.name` | `cc-name` |
| `payment.card.expiry` | `cc-exp` |
| `payment.card.expiryMonth` / `payment.card.expiryYear` | `cc-exp-month` / `cc-exp-year` |
| `payment.card.securityCode` | `cc-csc` |
| `person.name` / `person.givenName` / `person.familyName` | `name` / `given-name` / `family-name` |
| `person.email` / `person.phone` | `email` / `tel` |
| `person.address.street` | `street-address` |
| `person.address.line1` / `person.address.line2` | `address-line1` / `address-line2` |
| `person.address.city` / `person.address.region` | `address-level2` / `address-level1` |
| `person.address.postalCode` / `person.address.country` | `postal-code` / `country-name` |
| `account.username` / `account.password` | `username` / `current-password` |

An optional `context: "billing"` or `context: "shipping"` requires that explicit
autocomplete context, distinguishing two address forms. A saved `selector`
overrides automatic matching, including context selection. It still undergoes
all destination and form checks. Unknown semantic types or contexts are rejected.
Values are filled verbatim; expiry-format conversion and select controls are not
implemented. The driver retains the selected DOM element and rechecks both its
identity and the mapping after the provider returns, rejecting replaced controls,
new ambiguity or changed semantic hints.

Login profiles may now omit `usernameSelector` and `passwordSelector` to use
`account.username` and `account.password` discovery. The saved `submitSelector`
and `successSelector` remain required so a guessed button or page change cannot
establish successful authentication. Naninunu's UI has not yet been updated to
make its selector inputs optional.
