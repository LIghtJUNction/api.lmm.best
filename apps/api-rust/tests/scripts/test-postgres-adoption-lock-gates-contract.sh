#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
harness="$repo/apps/api-rust/tests/scripts/run-postgres-adoption-lock-gates.sh"
runtime=$(mktemp -d "$repo/.postgres-adoption-contract.XXXXXXXX")
trap 'if [[ ${LMM_KEEP_CONTRACT_RUNTIME:-0} != 1 ]]; then rm -rf -- "$runtime"; else printf "contract runtime retained: %s\n" "$runtime" >&2; fi' EXIT

fail() { printf 'postgres-adoption-lock-contract: %s\n' "$*" >&2; exit 1; }
expect_fail() {
  if "$@" >"$runtime/expected-failure.out" 2>"$runtime/expected-failure.err"; then
    fail "expected failure: $*"
  fi
}
reset_fake_daemon_state() {
  rm -f -- "$FAKE_ROOT/postgres.args" "$FAKE_ROOT/postgres.pid" \
    "$FAKE_ROOT/valkey-server.args" "$FAKE_ROOT/valkey-server.pid" \
    "$FAKE_ROOT/pg-ready-count" "$FAKE_ROOT/listener-state"
}
harness_run() { reset_fake_daemon_state; PATH="$FAKE_ROOT:$PATH" bash "$harness" "$@"; }
harness_with_fake_stat() { PATH="$FAKE_ROOT:$PATH" harness_run "$@"; }
assert_before() {
  local earlier=$1 later=$2 earlier_line later_line
  earlier_line=$(grep -n -m1 -F -- "$earlier" "$FAKE_ROOT/events" | cut -d: -f1)
  later_line=$(grep -n -m1 -F -- "$later" "$FAKE_ROOT/events" | cut -d: -f1)
  [[ -n $earlier_line && -n $later_line && $earlier_line -lt $later_line ]] ||
    fail "expected '$earlier' before '$later'"
}

for command_name in bash cc cp cut grep realpath shellcheck stat; do
  command -v "$command_name" >/dev/null || fail "missing contract-test command: $command_name"
done
bash -n "$harness"
shellcheck "$harness"

fake_root="$runtime/fake"
mkdir -m 0700 -- "$fake_root"
export FAKE_ROOT=$fake_root
export LMM_ADOPTION_CONTRACT_FAKE_ROOT=$fake_root

cat >"$runtime/fake-daemon.c" <<'EOF'
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void append_event(const char *name) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/events", getenv("FAKE_ROOT"));
  FILE *file = fopen(path, "a");
  if (!file) exit(90);
  fprintf(file, "%s\n", name);
  fclose(file);
}

static void record_args(const char *name, int argc, char **argv) {
  char path[4096];
  snprintf(path, sizeof(path), "%s/%s.args", getenv("FAKE_ROOT"), name);
  FILE *file = fopen(path, "w");
  if (!file) exit(91);
  for (int i = 1; i < argc; i++) fprintf(file, "%s\n", argv[i]);
  fclose(file);
}

static void write_pidfile_from_config(const char *config) {
  FILE *input = fopen(config, "r");
  if (!input) exit(92);
  char line[4096];
  while (fgets(line, sizeof(line), input)) {
    if (strncmp(line, "pidfile ", 8) == 0) {
      line[strcspn(line, "\r\n")] = 0;
      FILE *output = fopen(line + 8, "w");
      if (!output) exit(93);
      fprintf(output, "%ld\n", (long)getpid());
      fclose(output);
    }
  }
  fclose(input);
}

int main(int argc, char **argv) {
  char *name = basename(argv[0]);
  if (argc == 2 && strcmp(argv[1], "--version") == 0) {
    if (strcmp(name, "postgres") == 0) puts("postgres (PostgreSQL) 18.3");
    else puts("Valkey server v=8.1.2 sha=00000000 malloc=libc bits=64 build=test");
    return 0;
  }
  append_event(name);
  record_args(name, argc, argv);
  char pidpath[4096];
  snprintf(pidpath, sizeof(pidpath), "%s/%s.pid", getenv("FAKE_ROOT"), name);
  FILE *pid = fopen(pidpath, "w");
  if (!pid) return 94;
  fprintf(pid, "%ld\n", (long)getpid());
  fclose(pid);
  if (strcmp(name, "valkey-server") == 0 && argc >= 2) write_pidfile_from_config(argv[1]);
  for (;;) pause();
}
EOF
cc -O2 -o "$fake_root/postgres" "$runtime/fake-daemon.c"
cp -- "$fake_root/postgres" "$fake_root/valkey-server"
chmod 0700 -- "$fake_root/postgres" "$fake_root/valkey-server"

cat >"$fake_root/initdb" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == --version ]]; then printf 'initdb (PostgreSQL) 18.3\n'; exit 0; fi
printf 'initdb\n' >>"$FAKE_ROOT/events"
for argument in "$@"; do
  case $argument in --pgdata=*) pgdata=${argument#--pgdata=} ;; esac
done
mkdir -p -- "$pgdata"
printf 'local all all scram-sha-256\nhost all all 127.0.0.1/32 scram-sha-256\n' >"$pgdata/pg_hba.conf"
EOF

cat >"$fake_root/psql" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'psql\n' >>"$FAKE_ROOT/events"
{
  printf '%s\n' '---'
  printf '%s\n' "$@"
} >>"$FAKE_ROOT/psql.args"
[[ -f ${PGPASSFILE:-} && $(stat -c %a -- "$PGPASSFILE") == 600 ]] || exit 18
while IFS=: read -r _ _ _ _ password; do
  for argument in "$@"; do
    [[ $argument != *"$password"* && $argument != postgresql://* ]] || exit 19
  done
done <"$PGPASSFILE"
sql_file=''; query=''; role=''; database=''
while (($#)); do
  case $1 in
    -f) sql_file=$2; shift 2 ;;
    -Atqc) query=$2; shift 2 ;;
    -U) role=$2; shift 2 ;;
    -d) database=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [[ $query == 'SELECT 1' ]]; then
  ready_count=0
  if [[ -f $FAKE_ROOT/pg-ready-count ]]; then ready_count=$(<"$FAKE_ROOT/pg-ready-count"); fi
  ((ready_count += 1))
  printf '%s\n' "$ready_count" >"$FAKE_ROOT/pg-ready-count"
  if ((ready_count <= ${LMM_ADOPTION_CONTRACT_PG_READY_FAILS:-0})); then
    exit 17
  fi
  printf 'pg-ready\n' >>"$FAKE_ROOT/events"
fi
if [[ -n $sql_file ]]; then
  if grep -q '^CREATE ROLE ' "$sql_file"; then
    printf 'create-role\n' >>"$FAKE_ROOT/events"
    cp -- "$sql_file" "$FAKE_ROOT/create-role.sql"
  elif grep -q '^CREATE DATABASE ' "$sql_file"; then
    printf 'create-database\n' >>"$FAKE_ROOT/events"
    cp -- "$sql_file" "$FAKE_ROOT/create-database.sql"
  elif grep -q '^ALTER ROLE .* IN DATABASE .* SET search_path = public;' "$sql_file"; then
    printf 'set-search-path\n' >>"$FAKE_ROOT/events"
    cp -- "$sql_file" "$FAKE_ROOT/set-search-path.sql"
  else
    exit 20
  fi
elif [[ $query == *current_database* ]]; then
  superuser_value=${LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE-false}
  lmm_meta_value=${LMM_ADOPTION_CONTRACT_LMM_META_VALUE-false}
  if [[ ${LMM_ADOPTION_CONTRACT_BAD_IDENTITY:-0} == 1 ]]; then
    printf '%s|%s|public|%s|1|%s|0\n' "$database" "$role" "$superuser_value" "$lmm_meta_value"
  else
    printf '%s|%s|public|%s|0|%s|0\n' "$database" "$role" "$superuser_value" "$lmm_meta_value"
  fi
elif [[ $query == 'SHOW search_path' ]]; then
  if [[ ${LMM_ADOPTION_CONTRACT_BAD_SEARCH_PATH:-0} == 1 ]]; then printf '"$user", public\n'; else printf 'public\n'; fi
else
  printf '1\n'
fi
EOF

cat >"$fake_root/valkey-cli" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == --version ]]; then printf 'valkey-cli 8.1.2\n'; exit 0; fi
printf 'valkey-cli\n' >>"$FAKE_ROOT/events"
printf '%s\n' "$@" >>"$FAKE_ROOT/valkey-cli.args"
exit_on_error=0
for argument in "$@"; do
  [[ $argument == -e ]] && exit_on_error=1
done
if [[ -z ${VALKEYCLI_AUTH:-} ]]; then
  printf 'NOAUTH Authentication required.\n'
  ((exit_on_error == 1)) && exit 1
  exit 0
fi
printf 'PONG\n'
EOF

cat >"$fake_root/ss" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ -f $FAKE_ROOT/postgres.pid && -f $FAKE_ROOT/postgres.args ]]; then
  postgres_pid=$(<"$FAKE_ROOT/postgres.pid")
  if kill -0 "$postgres_pid" 2>/dev/null; then
    postgres_socket=$(sed -n 's/^unix_socket_directories=//p' "$FAKE_ROOT/postgres.args")
    if [[ -n $postgres_socket ]]; then
      postgres_port=$(awk 'previous == "-p" {print; exit} {previous=$0}' "$FAKE_ROOT/postgres.args")
      printf 'u_str LISTEN 0 128 %s/.s.PGSQL.%s users:(("postgres",pid=%s,fd=5))\n' \
        "$postgres_socket" "$postgres_port" "$postgres_pid"
    else
      postgres_port=$(awk 'previous == "-p" {print; exit} {previous=$0}' "$FAKE_ROOT/postgres.args")
      [[ -n $postgres_port ]] &&
        printf 'LISTEN 0 128 127.0.0.1:%s users:(("postgres",pid=%s,fd=5))\n' "$postgres_port" "$postgres_pid"
    fi
  fi
fi
if [[ -f $FAKE_ROOT/valkey-server.pid && -f $FAKE_ROOT/valkey-server.args ]]; then
  valkey_pid=$(<"$FAKE_ROOT/valkey-server.pid")
  if kill -0 "$valkey_pid" 2>/dev/null; then
    config=$(<"$FAKE_ROOT/valkey-server.args")
    valkey_socket=$(awk '/^unixsocket /{print $2}' "$config")
    if [[ -n $valkey_socket ]]; then
      printf 'u_str LISTEN 0 128 %s users:(("valkey-server",pid=%s,fd=6))\n' "$valkey_socket" "$valkey_pid"
    else
      valkey_port=$(awk '/^port /{print $2}' "$config")
      [[ -n $valkey_port ]] &&
        printf 'LISTEN 0 128 127.0.0.1:%s users:(("valkey-server",pid=%s,fd=6))\n' "$valkey_port" "$valkey_pid"
    fi
  fi
fi
EOF

cat >"$fake_root/cargo" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'cargo\n' >>"$FAKE_ROOT/events"
{
  printf '%s\n' '---'
  printf '%s\n' "$@"
} >>"$FAKE_ROOT/cargo.args"
[[ $LMM_TEST_ADOPT_DATABASE_URL == postgresql://* ]] || exit 31
[[ -z ${LMM_TEST_ADOPT_VALKEY_URL:-} ]] || exit 32
if [[ $LMM_TEST_ADOPT_DATABASE_URL == *'?host=%2F'* ]]; then
  [[ $LMM_TEST_ADOPT_DATABASE_URL == postgresql://*'@/'* ]] || exit 33
  [[ $LMM_TEST_ADOPT_DATABASE_URL != *'@localhost'* ]] || exit 34
  [[ $LMM_TEST_ADOPT_DATABASE_URL == *'&port=5432&connect_timeout=5' ]] || exit 35
  socket=$(sed -n 's/^unix_socket_directories=//p' "$FAKE_ROOT/postgres.args")
  encoded_socket=${socket//\//%2F}
  role=$(sed -n 's/^CREATE ROLE "\([^"]*\)".*/\1/p' "$FAKE_ROOT/create-role.sql")
  database=$(sed -n 's/^CREATE DATABASE "\([^"]*\)".*/\1/p' "$FAKE_ROOT/create-database.sql")
  run_pgpass="${CARGO_TARGET_DIR%/cargo-target}/config/pgpass"
  password=$(awk -F: -v database="$database" '$3 == database {print $5}' "$run_pgpass")
  expected_url="postgresql://$role:$password@/$database?host=$encoded_socket&port=5432&connect_timeout=5"
  [[ $LMM_TEST_ADOPT_DATABASE_URL == "$expected_url" ]] || exit 36
fi
{
  printf 'database_url_present=true\n'
  printf 'valkey_url_absent=true\n'
  printf 'home_isolated=%s\n' "$([[ $HOME == */home ]] && printf true || printf false)"
  printf 'tmpdir_isolated=%s\n' "$([[ $TMPDIR == */tmp ]] && printf true || printf false)"
  printf 'target_isolated=%s\n' "$([[ $CARGO_TARGET_DIR == */cargo-target ]] && printf true || printf false)"
  if [[ $LMM_TEST_ADOPT_DATABASE_URL == *'?host=%2F'* ]]; then
    printf 'unix_dsn_exact=true\nunix_authority_empty=true\nunix_host_count=1\nunix_connect_timeout=5\n'
  fi
} >"$FAKE_ROOT/cargo.env.safe"
printf 'injected database secret for redaction: %s\n' "$LMM_TEST_ADOPT_DATABASE_URL"
printf 'argv0=%s\n' "$0" >"$FAKE_ROOT/cargo.argv0"
if [[ -n ${LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT:-} && ${LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT} == "$LMM_ADOPTION_CONTRACT_CARGO_INDEX" ]]; then exit 41; fi
printf '%s\n' "$LMM_ADOPTION_CONTRACT_CARGO_INDEX" >>"$FAKE_ROOT/cargo.indices"
EOF
chmod 0700 -- "$fake_root/initdb" "$fake_root/psql" "$fake_root/valkey-cli" "$fake_root/ss" "$fake_root/cargo"
cat >"$fake_root/stat" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == /usr/bin/false ]]; then
  [[ ${LMM_ADOPTION_CONTRACT_STAT_OWNER:-0} == 1 ]] && printf '1000\n' || printf '0\n'
  exit 0
fi
if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$FAKE_ROOT/cargo" ]]; then
  printf '0\n'
  exit 0
fi
if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$(dirname -- "$FAKE_ROOT")/cargo-proxy" ]]; then
  printf '0\n'
  exit 0
fi
if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$(dirname -- "$FAKE_ROOT")/safe-cargo-link" ]]; then
  printf '0\n'
  exit 0
fi
if [[ ${1:-} == -c && ${2:-} == %a && ${4:-} == /usr/bin/false ]]; then
  [[ ${LMM_ADOPTION_CONTRACT_STAT_MODE:-0} == 1 ]] && printf '777\n' || printf '755\n'
  exit 0
fi
if [[ ${1:-} == -c && ${2:-} == %a && ${4:-} == "$FAKE_ROOT/cargo" ]]; then
  printf '755\n'
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod 0700 -- "$fake_root/stat"

workspace="$runtime/postgres-adoption-contract"
mkdir -m 0700 -- "$workspace"
marker="$workspace/.lmm-deploy-workspace"
{
  printf 'format=1\n'
  printf 'deployment_id=postgres-adoption-contract\n'
  printf 'role=controller\n'
  printf 'workspace=%s\n' "$workspace"
  printf 'created_at_utc=2026-08-07T00:00:00Z\n'
} >"$marker"
chmod 0600 -- "$marker"

common_args=(--workspace "$workspace" --workspace-marker "$marker" --transport tcp
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql"
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli"
  --cargo "$fake_root/cargo" --ss "$fake_root/ss")
proxy_cargo_link="$runtime/cargo-proxy"
ln -s -- "$fake_root/cargo" "$proxy_cargo_link"
proxy_args=(--workspace "$workspace" --workspace-marker "$marker" --transport tcp
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql"
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli"
  --cargo "$proxy_cargo_link" --ss "$fake_root/ss")
export LMM_ADOPTION_CONTRACT_PG_READY_FAILS=3

safe_target=$(realpath -e -- /usr/bin/false)
safe_cargo_link="$runtime/safe-cargo-link"
ln -s -- "$safe_target" "$safe_cargo_link"
: >"$FAKE_ROOT/events"
expect_fail harness_with_fake_stat --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$safe_cargo_link" --ss "$fake_root/ss"
grep -q '^initdb$' "$FAKE_ROOT/events" || fail 'safe root-owned Cargo symlink was rejected before setup'
grep -R -Fq "cargo_resolved_target=$safe_target" "$workspace" ||
  fail 'resolved Cargo symlink target was not recorded'
export LMM_ADOPTION_CONTRACT_STAT_OWNER=1
: >"$FAKE_ROOT/events"
expect_fail harness_with_fake_stat --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$safe_cargo_link" --ss "$fake_root/ss"
unset LMM_ADOPTION_CONTRACT_STAT_OWNER
! grep -q '^initdb$' "$FAKE_ROOT/events" || fail 'non-root Cargo symlink target was accepted'
export LMM_ADOPTION_CONTRACT_STAT_MODE=1
: >"$FAKE_ROOT/events"
expect_fail harness_with_fake_stat --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$safe_cargo_link" --ss "$fake_root/ss"
unset LMM_ADOPTION_CONTRACT_STAT_MODE
! grep -q '^initdb$' "$FAKE_ROOT/events" || fail 'writable Cargo symlink target was accepted'
relative_cargo_link="$runtime/relative-cargo-link"
ln -s -- "fake/cargo" "$relative_cargo_link"
: >"$FAKE_ROOT/events"
expect_fail harness_run --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$relative_cargo_link" --ss "$fake_root/ss"
! grep -q '^initdb$' "$FAKE_ROOT/events" || fail 'relative Cargo symlink target was accepted'
dangling_cargo_link="$runtime/dangling-cargo-link"
ln -s -- /run/lmm-adoption-cargo-does-not-exist "$dangling_cargo_link"
: >"$FAKE_ROOT/events"
expect_fail harness_run --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$dangling_cargo_link" --ss "$fake_root/ss"
! grep -q '^initdb$' "$FAKE_ROOT/events" || fail 'dangling Cargo symlink was accepted'

expect_fail harness_run --workspace / --workspace-marker "$marker" \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$fake_root/cargo" --ss "$fake_root/ss"
bad_marker="$workspace/bad-marker"
printf 'format=1\nrole=controller\nworkspace=%s\n' "$workspace" >"$bad_marker"
expect_fail harness_run --workspace "$workspace" --workspace-marker "$bad_marker" \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$fake_root/cargo" --ss "$fake_root/ss"
wrong_name_marker="$workspace/.wrong-marker"
cp -- "$marker" "$wrong_name_marker"
expect_fail harness_run --workspace "$workspace" --workspace-marker "$wrong_name_marker" \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$fake_root/cargo" --ss "$fake_root/ss"
chmod 0644 -- "$marker"
expect_fail harness_run "${common_args[@]}"
chmod 0600 -- "$marker"
symlink_workspace="$runtime/workspace-link"
ln -s -- "$workspace" "$symlink_workspace"
expect_fail harness_run --workspace "$symlink_workspace" --workspace-marker "$marker" \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$fake_root/cargo" --ss "$fake_root/ss"

: >"$fake_root/events"
rm -f -- "$fake_root/valkey-cli.args" "$fake_root/cargo.argv0"
export LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE=f
export LMM_ADOPTION_CONTRACT_LMM_META_VALUE=false
harness_with_fake_stat "${proxy_args[@]}" >"$runtime/harness.out" 2>"$runtime/harness.err"
unset LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE LMM_ADOPTION_CONTRACT_LMM_META_VALUE

assert_before initdb postgres
assert_before postgres pg-ready
assert_before pg-ready create-role
assert_before postgres create-role
assert_before create-role create-database
assert_before create-database set-search-path
assert_before set-search-path valkey-server
assert_before valkey-server cargo
grep -Fqx -- '-e' "$FAKE_ROOT/valkey-cli.args" || fail 'unauthenticated Valkey probe did not request CLI error exit status'
[[ $(grep -c '^cargo$' "$FAKE_ROOT/events") == 6 ]] || fail 'Cargo did not run exactly six exact invocations'
grep -q '^CREATE ROLE ' "$FAKE_ROOT/create-role.sql" || fail 'CREATE ROLE was not issued separately'
! grep -q 'CREATE DATABASE' "$FAKE_ROOT/create-role.sql" || fail 'role SQL also created the database'
grep -q '^CREATE DATABASE ' "$FAKE_ROOT/create-database.sql" || fail 'CREATE DATABASE was not issued separately'
! grep -q 'CREATE ROLE' "$FAKE_ROOT/create-database.sql" || fail 'database SQL also created the role'
grep -q '^ALTER ROLE .* IN DATABASE .* SET search_path = public;$' "$FAKE_ROOT/set-search-path.sql" ||
  fail 'role/database-specific public search_path was not configured'
! grep -Eq 'postgresql://|redis://|redis\+unix://' "$FAKE_ROOT/psql.args" || fail 'a DSN appeared in psql argv'
while IFS= read -r pgpass_path; do
  while IFS=: read -r _ _ _ _ password; do
    ! grep -Fq "$password" "$FAKE_ROOT/psql.args" || fail 'a PostgreSQL password appeared in psql argv'
  done <"$pgpass_path"
done < <(find "$workspace" -name pgpass -type f -print | sort)

expected_manifest="$repo/apps/api-rust/Cargo.toml"
expected_args=$(cat <<EOF
---
test
--locked
--manifest-path
$expected_manifest
--package
lmm-db-migrate
--test
postgres_adopt_existing
--
adoption_should_commit_once_replay_without_writes_and_reject_partial_ledger
--ignored
--exact
--test-threads=1
EOF
)
[[ $(sed -n '1,14p' "$FAKE_ROOT/cargo.args") == "$expected_args" ]] || fail 'Cargo argv is not the exact six-test command grammar'
grep -Fqx "argv0=$proxy_cargo_link" "$FAKE_ROOT/cargo.argv0" || fail 'Cargo did not execute through the supplied proxy path'
[[ $(grep -c '^cargo$' "$FAKE_ROOT/events") == 6 ]] || fail 'Cargo did not run exactly six exact invocations'
expected_indices=$'1\n2\n3\n4\n5\n6'
[[ $(<"$FAKE_ROOT/cargo.indices") == "$expected_indices" ]] || fail 'Cargo exact invocation index sequence is wrong'
[[ $(grep -c '^--ignored$' "$FAKE_ROOT/cargo.args") == 6 ]] || fail 'each Cargo invocation must select ignored tests'
[[ $(grep -c '^--exact$' "$FAKE_ROOT/cargo.args") == 6 ]] || fail 'each Cargo invocation must use exact filtering'
for test_name in "${expected_tests[@]}"; do
  [[ $(grep -Fxc "$test_name" "$FAKE_ROOT/cargo.args") == 1 ]] || fail "exact Cargo test missing or duplicated: $test_name"
done
grep -Fqx 'database_url_present=true' "$FAKE_ROOT/cargo.env.safe" || fail 'required database URL missing from Cargo child env'
grep -Fqx 'valkey_url_absent=true' "$FAKE_ROOT/cargo.env.safe" || fail 'unneeded Valkey URL entered Cargo child env'
grep -Fqx 'home_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Cargo HOME was not isolated'
grep -Fqx 'tmpdir_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Cargo TMPDIR was not isolated'
grep -Fqx 'target_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Cargo target was not isolated'
# shellcheck disable=SC2016 # Bind the literal single-host Unix DSN construction.
grep -Fq 'database_url="postgresql://$pg_app:$pg_app_password@/$pg_database?host=$encoded_socket&port=$pg_port&connect_timeout=5"' "$harness" ||
  fail 'Unix Cargo DSN does not use one bounded socket host'
# shellcheck disable=SC2016 # Reject the literal multi-host Unix DSN construction.
! grep -Fq 'database_url="postgresql://$pg_app:$pg_app_password@localhost:' "$harness" ||
  fail 'Unix Cargo DSN still contains an authority host'

test_source="$repo/apps/api-rust/crates/lmm-db-migrate/tests/postgres_adopt_existing.rs"
mapfile -t scoped_tests < <(awk '/^#\[test\]$/ { seen=1; next } seen && /^#\[ignore = / { ignored=1; next } seen && /^fn / { if (ignored) { name=$2; sub(/\(.*/, "", name); print name } seen=0; ignored=0 }' "$test_source")
expected_tests=(adoption_should_commit_once_replay_without_writes_and_reject_partial_ledger
  catalog_lock_should_acquire_immediately_when_uncontended catalog_lock_should_time_out_when_contended
  catalog_lock_should_release_after_holder_rollback catalog_lock_should_release_after_holder_commit
  adoption_lock_timeout_should_not_create_ledger)
[[ ${#scoped_tests[@]} == 6 ]] || fail 'test binary no longer has exactly six ignored tests'
for index in "${!expected_tests[@]}"; do
  [[ ${scoped_tests[$index]} == "${expected_tests[$index]}" ]] || fail 'six-test source contract changed'
done

mapfile -t pass_statuses < <(find "$workspace" -mindepth 3 -maxdepth 3 -type f -path '*/evidence/status' \
  -exec grep -lFx PASS {} \; | sort)
[[ ${#pass_statuses[@]} == 1 ]] || fail 'expected exactly one durable PASS run'
evidence=$(dirname -- "${pass_statuses[0]}")
(cd -- "$evidence" && sha256sum -c SHA256SUMS >/dev/null) || fail 'evidence checksums failed'
grep -Fqx "cargo_resolved_target=$fake_root/cargo" "$evidence/checks.txt" ||
  fail 'Cargo proxy evidence did not retain the canonical target identity'
expected_cargo_sha=$(sha256sum -- "$fake_root/cargo")
expected_cargo_sha=${expected_cargo_sha%% *}
grep -Fqx "cargo_resolved_sha256=$expected_cargo_sha" "$evidence/checks.txt" ||
  fail 'Cargo proxy evidence did not hash the canonical target'
grep -Fq 'configured_search_path=public' "$evidence/postgres-identity.txt" || fail 'sanitized identity report omitted search_path'
grep -Fq 'public_schema_objects=0' "$evidence/postgres-identity.txt" || fail 'sanitized identity report omitted public count'
grep -Fq 'role_superuser=f' "$evidence/postgres-identity.txt" || fail 'sanitized identity report omitted raw f superuser state'
grep -Fq 'role_superuser_normalized=f' "$evidence/postgres-identity.txt" || fail 'false boolean was not normalized to f'
grep -Fq 'lmm_meta_present=false' "$evidence/postgres-identity.txt" || fail 'sanitized identity report omitted raw false lmm_meta state'
grep -Fq 'lmm_meta_present_normalized=f' "$evidence/postgres-identity.txt" || fail 'lmm_meta false boolean was not normalized to f'
grep -Fq '[REDACTED_DSN]' "$evidence/cargo.log" || fail 'injected database DSN was not transformed by redaction'
! grep -Eq 'postgresql://|redis\+unix://|redis://' "$evidence/cargo.log" || fail 'credential-bearing DSN leaked into evidence'
# shellcheck disable=SC2016 # Match the literal safety-critical source expression.
grep -Fq 'mktemp -d "$runtime_parent/lmm-a-XXXXXX"' "$harness" || fail 'short Unix socket directory contract is missing'
postgres_pid=$(<"$FAKE_ROOT/postgres.pid")
valkey_pid=$(<"$FAKE_ROOT/valkey-server.pid")
! kill -0 "$postgres_pid" 2>/dev/null || fail 'PostgreSQL fake was not torn down'
! kill -0 "$valkey_pid" 2>/dev/null || fail 'Valkey fake was not torn down'

runtime_parent="/run/user/$(id -u)"
[[ -d $runtime_parent && ! -L $runtime_parent && $(stat -c %u -- "$runtime_parent") == "$EUID" ]] ||
  fail 'fake Unix contract requires the private runtime directory'
: >"$FAKE_ROOT/events"
rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" \
  "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args" \
  "$FAKE_ROOT/valkey-cli.args" "$FAKE_ROOT/cargo.argv0" "$FAKE_ROOT/cargo.env.safe"
export LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE=false
export LMM_ADOPTION_CONTRACT_LMM_META_VALUE=false
harness_with_fake_stat --workspace "$workspace" --workspace-marker "$marker" --transport unix \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$proxy_cargo_link" --ss "$fake_root/ss" >"$runtime/unix-harness.out" 2>"$runtime/unix-harness.err"
unset LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE LMM_ADOPTION_CONTRACT_LMM_META_VALUE
grep -Fqx 'unix_dsn_exact=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo did not receive the exact DSN'
grep -Fqx 'unix_authority_empty=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo DSN authority was not empty'
grep -Fqx 'unix_host_count=1' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo DSN did not have exactly one host'
grep -Fqx 'unix_connect_timeout=5' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo DSN timeout was not bounded'
grep -Fqx 'database_url_present=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo database URL was absent'
grep -Fqx 'valkey_url_absent=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo inherited an unneeded Valkey URL'
grep -Fqx 'home_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo HOME was not isolated'
grep -Fqx 'tmpdir_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo TMPDIR was not isolated'
grep -Fqx 'target_isolated=true' "$FAKE_ROOT/cargo.env.safe" || fail 'Unix fake Cargo target was not isolated'
! grep -Eq 'postgresql://|redis\+unix://|redis://' "$runtime/unix-harness.out" "$runtime/unix-harness.err" ||
  fail 'Unix fake harness leaked a DSN into its outer logs'
! grep -Eq 'postgresql://|redis\+unix://|redis://' "$FAKE_ROOT/cargo.args" ||
  fail 'Unix fake harness placed a DSN in Cargo argv'
unix_postgres_pid=$(<"$FAKE_ROOT/postgres.pid")
unix_valkey_pid=$(<"$FAKE_ROOT/valkey-server.pid")
! kill -0 "$unix_postgres_pid" 2>/dev/null || fail 'Unix fake PostgreSQL was not torn down'
! kill -0 "$unix_valkey_pid" 2>/dev/null || fail 'Unix fake Valkey was not torn down'

: >"$FAKE_ROOT/events"
rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" \
  "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
export LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE=f
export LMM_ADOPTION_CONTRACT_LMM_META_VALUE=f
export LMM_ADOPTION_CONTRACT_BAD_IDENTITY=1
f_boolean_boundary="$runtime/f-boolean-boundary"
: >"$f_boolean_boundary"
expect_fail harness_run "${common_args[@]}"
unset LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE LMM_ADOPTION_CONTRACT_LMM_META_VALUE LMM_ADOPTION_CONTRACT_BAD_IDENTITY
mapfile -t f_boolean_runs < <(find "$workspace" -mindepth 1 -maxdepth 1 -type d \
  -name 'postgres-adoption-lock-*' -newer "$f_boolean_boundary" -print | sort)
[[ ${#f_boolean_runs[@]} == 1 ]] || fail 'could not identify safe f boolean fixture run'
f_boolean_evidence="${f_boolean_runs[0]}/evidence"
grep -Fq 'identity mismatch: public schema is not empty' "$f_boolean_evidence/postgres-identity-failure.txt" ||
  fail 'safe f boolean did not pass normalization before the public-schema check'
grep -Fq 'lmm_meta_present=f' "$f_boolean_evidence/postgres-identity.txt" ||
  fail 'safe f lmm_meta state was not recorded'
grep -Fq 'lmm_meta_present_normalized=f' "$f_boolean_evidence/postgres-identity.txt" ||
  fail 'safe f lmm_meta state was not normalized to f'
! grep -q '^valkey-server$' "$FAKE_ROOT/events" || fail 'Valkey ran for safe f identity fixture'
! grep -q '^cargo$' "$FAKE_ROOT/events" || fail 'Cargo ran for safe f identity fixture'

: >"$FAKE_ROOT/events"
export LMM_ADOPTION_CONTRACT_PG_READY_FAILS=201
expect_fail harness_run "${common_args[@]}"
export LMM_ADOPTION_CONTRACT_PG_READY_FAILS=3
grep -Fq 'PostgreSQL readiness timed out before setup' "$runtime/expected-failure.err" ||
  fail 'readiness timeout did not report the exact setup error'
for forbidden_event in create-role create-database valkey-server cargo; do
  ! grep -Fqx "$forbidden_event" "$FAKE_ROOT/events" ||
    fail "readiness timeout reached forbidden event: $forbidden_event"
done
timeout_postgres_pid=$(<"$FAKE_ROOT/postgres.pid")
! kill -0 "$timeout_postgres_pid" 2>/dev/null || fail 'timed-out PostgreSQL fake was not torn down'
[[ ! -e $FAKE_ROOT/valkey-server.pid ]] || fail 'readiness timeout unexpectedly started Valkey'

: >"$FAKE_ROOT/events"
rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
export LMM_ADOPTION_CONTRACT_BAD_IDENTITY=1
identity_boundary="$runtime/identity-failure-boundary"
: >"$identity_boundary"
expect_fail harness_run "${common_args[@]}"
unset LMM_ADOPTION_CONTRACT_BAD_IDENTITY
mapfile -t identity_runs < <(find "$workspace" -mindepth 1 -maxdepth 1 -type d \
  -name 'postgres-adoption-lock-*' -newer "$identity_boundary" -print | sort)
[[ ${#identity_runs[@]} == 1 ]] || fail 'could not identify identity mismatch run'
identity_failure_evidence="${identity_runs[0]}/evidence"
grep -Fq 'identity mismatch: public schema is not empty' "$identity_failure_evidence/postgres-identity-failure.txt" ||
  fail 'identity mismatch reason was not durably persisted'
grep -Fq 'public_schema_objects=1' "$identity_failure_evidence/postgres-identity.txt" ||
  fail 'sanitized mismatching public count was not persisted'
! grep -q '^cargo$' "$FAKE_ROOT/events" || fail 'Cargo ran after identity mismatch'
identity_pid=$(<"$FAKE_ROOT/postgres.pid")
! kill -0 "$identity_pid" 2>/dev/null || fail 'identity mismatch PostgreSQL fake was not torn down'
[[ ! -e $FAKE_ROOT/valkey-server.pid ]] || fail 'identity mismatch unexpectedly started Valkey'

for unsafe_boolean in true t garbage ''; do
  : >"$FAKE_ROOT/events"
  rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
  boolean_boundary="$runtime/boolean-${unsafe_boolean:-empty}-boundary"
  : >"$boolean_boundary"
  export LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE="$unsafe_boolean"
  expect_fail harness_run "${common_args[@]}"
  unset LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE
  mapfile -t boolean_runs < <(find "$workspace" -mindepth 1 -maxdepth 1 -type d \
    -name 'postgres-adoption-lock-*' -newer "$boolean_boundary" -print | sort)
  [[ ${#boolean_runs[@]} == 1 ]] || fail "could not identify boolean fixture run: ${unsafe_boolean:-empty}"
  boolean_evidence="${boolean_runs[0]}/evidence"
  grep -Fq 'identity mismatch: role must be non-superuser' "$boolean_evidence/postgres-identity-failure.txt" ||
    fail "unsafe boolean was accepted: ${unsafe_boolean:-empty}"
  ! grep -q '^cargo$' "$FAKE_ROOT/events" || fail "Cargo ran for unsafe boolean: ${unsafe_boolean:-empty}"
done

for unsafe_lmm_meta in true t garbage ''; do
  : >"$FAKE_ROOT/events"
  rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" \
    "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
  lmm_meta_boundary="$runtime/lmm-meta-${unsafe_lmm_meta:-empty}-boundary"
  : >"$lmm_meta_boundary"
  export LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE=f
  export LMM_ADOPTION_CONTRACT_LMM_META_VALUE="$unsafe_lmm_meta"
  expect_fail harness_run "${common_args[@]}"
  unset LMM_ADOPTION_CONTRACT_SUPERUSER_VALUE LMM_ADOPTION_CONTRACT_LMM_META_VALUE
  mapfile -t lmm_meta_runs < <(find "$workspace" -mindepth 1 -maxdepth 1 -type d \
    -name 'postgres-adoption-lock-*' -newer "$lmm_meta_boundary" -print | sort)
  [[ ${#lmm_meta_runs[@]} == 1 ]] || fail "could not identify lmm_meta fixture run: ${unsafe_lmm_meta:-empty}"
  lmm_meta_evidence="${lmm_meta_runs[0]}/evidence"
  grep -Fq 'identity mismatch: lmm_meta must be absent and empty' "$lmm_meta_evidence/postgres-identity-failure.txt" ||
    fail "unsafe lmm_meta value was accepted: ${unsafe_lmm_meta:-empty}"
  case $unsafe_lmm_meta in
    true|t) grep -Fq 'lmm_meta_present_normalized=t' "$lmm_meta_evidence/postgres-identity.txt" ||
      fail "true lmm_meta value was not normalized to t: ${unsafe_lmm_meta:-empty}" ;;
    *) grep -Fqx 'lmm_meta_present_normalized=' "$lmm_meta_evidence/postgres-identity.txt" ||
      fail "invalid lmm_meta value was not diagnosed: ${unsafe_lmm_meta:-empty}" ;;
  esac
  ! grep -q '^valkey-server$' "$FAKE_ROOT/events" || fail "Valkey ran for unsafe lmm_meta: ${unsafe_lmm_meta:-empty}"
  ! grep -q '^cargo$' "$FAKE_ROOT/events" || fail "Cargo ran for unsafe lmm_meta: ${unsafe_lmm_meta:-empty}"
done

: >"$FAKE_ROOT/events"
rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" \
  "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
export LMM_ADOPTION_CONTRACT_BAD_SEARCH_PATH=1
expect_fail harness_run "${common_args[@]}"
unset LMM_ADOPTION_CONTRACT_BAD_SEARCH_PATH
grep -q '^set-search-path$' "$FAKE_ROOT/events" || fail 'search_path failure fixture did not reach configuration'
! grep -q '^cargo$' "$FAKE_ROOT/events" || fail 'Cargo ran after search_path verification failure'

: >"$FAKE_ROOT/events"
rm -f -- "$FAKE_ROOT/postgres.pid" "$FAKE_ROOT/postgres.args" "$FAKE_ROOT/valkey-server.pid" "$FAKE_ROOT/valkey-server.args"
export LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT=3
failure_boundary="$runtime/cargo-failure-boundary"
: >"$failure_boundary"
expect_fail harness_run "${common_args[@]}"
unset LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT
[[ $(grep -c '^cargo$' "$FAKE_ROOT/events") == 3 ]] || fail 'Cargo failure did not stop after the exact third invocation'
! find "$workspace" -name 'cargo.raw.log' -print | grep -q . || fail 'raw Cargo log was created'
mapfile -t failure_runs < <(find "$workspace" -mindepth 1 -maxdepth 1 -type d \
  -name 'postgres-adoption-lock-*' -newer "$failure_boundary" -print | sort)
[[ ${#failure_runs[@]} == 1 ]] || fail 'could not identify exact Cargo failure run'
grep -Fq '[REDACTED_DSN]' "${failure_runs[0]}/evidence/cargo.log" || fail 'streamed failure output was not redacted'

# Identity is fail-closed: a daemon path that becomes a shell interpreter never
# reaches Cargo, and cleanup refuses to signal a PID whose executable changed.
cp -- "$fake_root/postgres" "$fake_root/postgres.real"
cat >"$fake_root/postgres-script" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == --version ]]; then echo 'postgres (PostgreSQL) 18.3'; exit; fi
printf '%s\n' $$ >"$FAKE_ROOT/postgres-script.pid"
sleep 30
EOF
chmod 0700 -- "$fake_root/postgres-script"
: >"$fake_root/events"
reset_fake_daemon_state
expect_fail timeout 3 bash "$harness" --workspace "$workspace" --workspace-marker "$marker" --transport tcp \
  --initdb "$fake_root/initdb" --postgres "$fake_root/postgres-script" --psql "$fake_root/psql" \
  --valkey-server "$fake_root/valkey-server" --valkey-cli "$fake_root/valkey-cli" \
  --cargo "$fake_root/cargo" --ss "$fake_root/ss"
! grep -q '^cargo$' "$FAKE_ROOT/events" || fail 'Cargo ran after daemon identity failure'
if [[ -f $FAKE_ROOT/postgres-script.pid ]]; then
  script_pid=$(<"$FAKE_ROOT/postgres-script.pid")
  kill "$script_pid" 2>/dev/null || true
fi

printf 'PostgreSQL adoption lock harness contract tests passed\n'
