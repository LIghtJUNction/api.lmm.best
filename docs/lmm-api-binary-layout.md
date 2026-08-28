# `lmm-api` binary layout

## Durable invariant

`lmm-api` is a backend-selection link. It is never a compiled binary.

```text
/usr/bin/lmm-api-go   # real Go provider/server executable
/usr/bin/lmm-api-rs   # real Rust client/server executable
/usr/bin/lmm-api      # symlink to exactly one provider above
```

The Go package installs the initial selection as:

```text
lmm-api -> lmm-api-go
```

The Rust package installs `lmm-api-rs` without changing the existing selection.
The public Rust installers follow the same rule. Installing or updating bootstrap
commands must not silently switch a running backend.

## Rust command modes

`lmm-api-rs` owns both server and bootstrap client behavior:

```text
lmm-api-rs                 # start the Rust server (compatibility default)
lmm-api-rs serve           # start the Rust server explicitly
lmm-api-rs doctor          # inspect CC Switch and agent tooling
lmm-api-rs bootstrap ...   # install CC Switch and selected agents
lmm-api-rs login ...       # OAuth login, API-key selection, CC Switch import
```

There is no separate `lmm-api` bootstrap crate, package, or executable.

## Safety rules

- Provider executables must be regular executable files, never reverse aliases.
- `lmm-api` must be a relative symlink whose target basename is either
  `lmm-api-go` or `lmm-api-rs`.
- Package validation rejects mixed forward/reverse symlink layouts.
- Production Go services execute `/usr/bin/lmm-api-go` directly; changing the
  selection link alone cannot silently replace a running production backend.
- A backend cutover must validate the destination provider first and replace the
  symlink atomically as an explicit operation.
- Rollback verification continues to recognize historical package layouts, but
  new packages and releases may only emit the forward-link layout.
