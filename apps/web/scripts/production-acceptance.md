# Production post-deploy acceptance

`production-acceptance.mjs` performs a live, post-deploy acceptance run against
exactly `https://api.lmm.best`. It is deliberately separate from the deployment
transaction and does not modify release, service, database, payment, or Git
state.

Do not run it until the production release is ready for live acceptance. The
workflow creates one isolated common user and one API key, makes low-cost real
provider calls, then deletes the key and exact verified user. The isolated user
receives one fixed 10,000-unit quota override, verified through its exact admin
record and removed with the user during cleanup. Any retained identity is
reported in the redacted summary.

## Credential interface

The command accepts no arguments. Set exactly one of:

- `LMM_ACCEPTANCE_CREDENTIAL_FILE`: absolute path to a root-owned regular file
  with mode `0600`; symlinks are rejected.
- `LMM_ACCEPTANCE_CREDENTIAL_FD`: inherited, already-open descriptor above 2.

The credential content is JSON:

```json
{
  "username": "root-user",
  "password": "current-password",
  "totp_code": "current-code",
  "completion_model": "known-safe-chat-completion-model"
}
```

`totp_code` is required only when the root account requires 2FA.
`completion_model` is required and must name a deliberately selected model
known to support OpenAI-compatible chat completions. The runner verifies that
the exact model is present in the created API key's `/v1/models` response and
fails closed when it is unavailable. It never guesses from the model list.

File example:

```sh
sudo env LMM_ACCEPTANCE_CREDENTIAL_FILE=/etc/lmm-api/acceptance.json \
  node apps/web/scripts/production-acceptance.mjs
```

Inherited descriptor example:

```sh
sudo sh -c 'exec 3</etc/lmm-api/acceptance.json; LMM_ACCEPTANCE_CREDENTIAL_FD=3 exec node apps/web/scripts/production-acceptance.mjs'
```

Passwords, access tokens, cookies, 2FA codes, channel keys, and the created API
key remain in memory only. They are never accepted as arguments or written to
logs, summaries, or other artifacts.

## Guard contract

Stdout contains exactly one JSON object. `success` is true only when all
required checks and cleanup succeed; the process exits nonzero otherwise.
The `funded_test_user` check is boolean and never exposes quota or balance
values in the summary.
Channel results contain only ID, name, type, enabled state, and redacted
pass/fail status. Disabled channels are enumerated with `passed: null` and are
not called. Each enabled channel is tested exactly once, serially, through the
backend's bounded `/api/channel/test/:id` real validation route. The bulk test
route is not used, so acceptance cannot trigger automatic channel bans.

All HTTP calls have one hard deadline covering headers and the complete
response body. Bodies are read as a bounded stream and rejected as soon as
they exceed 1 MiB, including chunked responses without `Content-Length`. The
created API key must list OpenAI-compatible models and complete one
non-streaming request using the explicit model with `max_tokens: 1`.
Unsupported channel tests, timeouts, missing cleanup evidence, and an
unavailable explicit completion model are required failures.

Run the offline contract tests with:

```sh
node apps/web/scripts/production-acceptance.test.mjs
```
