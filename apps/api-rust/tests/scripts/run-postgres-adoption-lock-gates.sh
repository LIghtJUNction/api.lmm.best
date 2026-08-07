#!/usr/bin/env bash
# Run the six ignored postgres_adopt_existing integration tests against fresh,
# marker-owned PostgreSQL 18 and Valkey instances. No existing listener is used.
set -Eeuo pipefail

umask 077

usage() {
  cat >&2 <<'EOF'
usage: run-postgres-adoption-lock-gates.sh \
  --workspace ABS --workspace-marker ABS \
  [--transport unix|tcp] [--initdb ABS] [--postgres ABS] [--psql ABS] \
  [--valkey-server ABS] [--valkey-cli ABS] [--cargo ABS] [--ss ABS]

The default transport is unix. TCP loopback fallback must be selected explicitly
with --transport tcp. The supplied workspace must be an existing, private,
non-symlink controller workspace created by create-workspace.sh.
EOF
  return 2
}

die() {
  printf 'postgres-adoption-lock-gates: %s\n' "$*" >&2
  exit 1
}

resolve_command() {
  local name=$1 value=$2 resolved
  if [[ -z $value ]]; then
    resolved=$(command -v -- "$name") || die "missing required command: $name"
  else
    [[ $value == /* ]] || die "$name path must be absolute"
    resolved=$value
  fi
  [[ -f $resolved && ! -L $resolved && -x $resolved ]] ||
    die "$name must be an executable regular non-symlink file"
  realpath -e -- "$resolved"
}

resolve_cargo_command() {
  local value=$1 candidate target raw_target mode owner
  if [[ -z $value ]]; then
    candidate=$(command -v -- cargo) || die 'missing required command: cargo'
  else
    [[ $value == /* ]] || die 'cargo path must be absolute'
    candidate=$value
  fi
  [[ -e $candidate ]] || die 'cargo path is dangling'
  if [[ -L $candidate ]]; then
    raw_target=$(readlink -- "$candidate") || die 'could not read cargo symlink'
    [[ $raw_target == /* ]] || die 'cargo symlink target must be absolute'
    target=$(readlink -f -- "$candidate") || die 'cargo symlink target is dangling'
    [[ -f $target && ! -L $target && -x $target ]] || die 'cargo symlink target is not a regular executable'
    owner=$(stat -c %u -- "$target")
    [[ $owner == 0 ]] || die 'cargo symlink target must be root-owned'
    mode=$(stat -c %a -- "$target")
    [[ $mode =~ ^[0-7]+$ ]] || die 'cargo symlink target mode is invalid'
    if (( (8#$mode & 022) != 0 )); then
      die 'cargo symlink target is writable by group or other'
    fi
    printf '%s\n' "$target"
    return
  fi
  [[ -f $candidate && ! -L $candidate && -x $candidate ]] ||
    die 'cargo must be an executable regular non-symlink file'
  printf '%s\n' "$candidate"
}

resolve_cargo_execution_path() {
  local value=$1 candidate target owner mode
  if [[ -z $value ]]; then
    candidate=$(command -v -- cargo) || die 'missing required command: cargo'
  else
    [[ $value == /* ]] || die 'cargo path must be absolute'
    candidate=$value
  fi
  reject_unsafe_path_text "$candidate"
  [[ -e $candidate ]] || die 'cargo execution path is dangling'
  if [[ -L $candidate ]]; then
    owner=$(stat -c %u -- "$candidate") || die 'could not inspect cargo symlink owner'
    [[ $owner == 0 ]] || die 'cargo symlink must be root-owned'
    target=$(readlink -f -- "$candidate") || die 'cargo symlink target is dangling'
    [[ -f $target && ! -L $target && -x $target ]] || die 'cargo symlink target is not a regular executable'
    owner=$(stat -c %u -- "$target")
    [[ $owner == 0 ]] || die 'cargo symlink target must be root-owned'
    mode=$(stat -c %a -- "$target")
    [[ $mode =~ ^[0-7]+$ ]] || die 'cargo symlink target mode is invalid'
    (( (8#$mode & 022) == 0 )) || die 'cargo symlink target is writable by group or other'
  else
    [[ -f $candidate && ! -L $candidate && -x $candidate ]] || die 'cargo execution path must be a regular executable'
    owner=$(stat -c %u -- "$candidate")
    [[ $owner == 0 ]] || die 'cargo execution path must be root-owned'
    mode=$(stat -c %a -- "$candidate")
    [[ $mode =~ ^[0-7]+$ ]] || die 'cargo execution path mode is invalid'
    (( (8#$mode & 022) == 0 )) || die 'cargo execution path is writable by group or other'
  fi
  printf '%s\n' "$candidate"
}

reject_unsafe_path_text() {
  local value=$1
  [[ -n $value && $value != *$'\n'* && $value != *$'\r'* && $value != *$'\t'* ]] ||
    die 'path is empty or contains control characters'
  [[ $value != *'~'* && $value != *'$'* && $value != *'*'* &&
     $value != *'?'* && $value != *'['* && $value != *']'* &&
     $value != *'{'* && $value != *'}'* ]] ||
    die 'path contains unresolved shell syntax or a glob'
}

assert_no_symlink_components() {
  local path=$1 current='/' component
  local -a components=()
  IFS='/' read -r -a components <<<"${path#/}"
  for component in "${components[@]}"; do
    [[ -n $component ]] || continue
    if [[ $current == / ]]; then current="/$component"; else current="$current/$component"; fi
    [[ ! -L $current ]] || die 'path traverses a symbolic link'
  done
}

validate_workspace() {
  local canonical marker_canonical owner mode expected_workspace deployment_id
  reject_unsafe_path_text "$workspace"
  reject_unsafe_path_text "$workspace_marker"
  [[ $workspace == /* && $workspace_marker == /* ]] || die 'workspace and marker paths must be absolute'
  canonical=$(realpath -e -- "$workspace") || die 'workspace does not exist'
  marker_canonical=$(realpath -e -- "$workspace_marker") || die 'workspace marker does not exist'
  [[ $canonical == "$workspace" && $marker_canonical == "$workspace_marker" ]] ||
    die 'workspace and marker paths must be canonical'
  assert_no_symlink_components "$workspace"
  assert_no_symlink_components "$workspace_marker"
  [[ -d $workspace && ! -L $workspace ]] || die 'workspace must be a real directory'
  [[ -f $workspace_marker && ! -L $workspace_marker ]] || die 'workspace marker must be a regular file'
  [[ $workspace_marker == "$workspace/.lmm-deploy-workspace" ]] ||
    die 'workspace marker must be the exact .lmm-deploy-workspace file'
  case $workspace in
    /|/home|/root|/usr|/var|/opt|/srv|/run|/tmp|/tmp/*|/var/tmp|/var/tmp/*)
      die 'workspace is a broad or forbidden temporary path'
      ;;
  esac
  if [[ -n ${HOME:-} ]]; then
    [[ $workspace != "$HOME" ]] || die 'workspace must not be the home directory'
  fi
  owner=$(stat -c %u -- "$workspace")
  [[ $owner == "$EUID" && $(stat -c %u -- "$workspace_marker") == "$EUID" ]] ||
    die 'workspace and marker must be owned by the invoking user'
  mode=$(stat -c %a -- "$workspace")
  [[ $mode == 700 ]] || die 'workspace mode must be 0700'
  [[ $(stat -c %a -- "$workspace_marker") == 600 ]] || die 'workspace marker mode must be 0600'
  grep -Fqx 'format=1' "$workspace_marker" || die 'workspace marker format is invalid'
  grep -Fqx 'role=controller' "$workspace_marker" || die 'workspace marker role must be controller'
  expected_workspace="workspace=$workspace"
  grep -Fqx "$expected_workspace" "$workspace_marker" || die 'workspace marker does not own this workspace'
  deployment_id=$(sed -n 's/^deployment_id=//p' "$workspace_marker")
  [[ $deployment_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die 'workspace marker deployment ID is invalid'
  [[ $deployment_id == "${workspace##*/}" ]] || die 'workspace basename must equal its marker deployment ID'
  [[ $(grep -Ec '^(format|deployment_id|role|workspace|created_at_utc)=' "$workspace_marker") == 5 &&
     $(wc -l <"$workspace_marker") == 5 ]] || die 'workspace marker must contain the exact create-workspace field set'
  grep -Eq '^created_at_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$workspace_marker" ||
    die 'workspace marker creation timestamp is invalid'
}

listener_is_unused() {
  local port=$1
  ! "$ss_bin" -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

choose_tcp_port() {
  local candidate attempts=0
  while ((attempts < 128)); do
    candidate=$((20000 + (16#$(od -An -N2 -tx2 /dev/urandom | tr -d ' ') % 30000)))
    if listener_is_unused "$candidate"; then printf '%s\n' "$candidate"; return 0; fi
    ((attempts += 1))
  done
  return 1
}

pid_executable_is() {
  local pid=$1 expected=$2 actual
  [[ $pid =~ ^[0-9]+$ && -e /proc/$pid/exe ]] || return 1
  actual=$(realpath -e -- "/proc/$pid/exe") || return 1
  [[ $actual == "$expected" ]]
}

unix_listener_belongs_to_pid() {
  local path=$1 pid=$2
  "$ss_bin" -H -xlpn 2>/dev/null | grep -F -- "$path" | grep -Eq "pid=$pid([,)]|$)"
}

tcp_listener_belongs_to_pid() {
  local port=$1 pid=$2
  "$ss_bin" -H -ltnp "sport = :$port" 2>/dev/null | grep -Eq "pid=$pid([,)]|$)"
}

stop_owned_pid() {
  local pid=$1 expected=$2 label=$3
  [[ $pid =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  if ! pid_executable_is "$pid" "$expected"; then
    printf 'postgres-adoption-lock-gates: refusing to stop %s: PID identity changed\n' "$label" >&2
    return 1
  fi
  kill -TERM "$pid" 2>/dev/null || return 1
  for _ in {1..100}; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid" 2>/dev/null || true; return 0; fi
    sleep 0.05
  done
  printf 'postgres-adoption-lock-gates: %s did not stop after TERM; evidence retained\n' "$label" >&2
  return 1
}

redact_stream() {
  local line
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line//"$database_url"/[REDACTED_DSN]}
    line=${line//"$valkey_url"/[REDACTED_DSN]}
    line=${line//"$pg_admin_password"/[REDACTED]}
    line=${line//"$pg_app_password"/[REDACTED]}
    line=${line//"$valkey_password"/[REDACTED]}
    printf '%s\n' "$line"
  done
}

write_final_status() {
  local state=$1 temporary="$evidence_dir/.status.$$"
  rm -f -- "$evidence_dir/status" "$temporary" || return 1
  printf '%s\n' "$state" >"$temporary" || return 1
  chmod 0600 -- "$temporary" || return 1
  "$sync_bin" -f "$temporary" || { rm -f -- "$temporary"; return 1; }
  mv -- "$temporary" "$evidence_dir/status" || return 1
  "$sync_bin" -f "$evidence_dir" || { rm -f -- "$evidence_dir/status"; return 1; }
}

sync_evidence() {
  "$sync_bin" -f "$evidence_dir/checks.txt" || return 1
  "$sync_bin" -f "$evidence_dir/cargo.log" || return 1
  "$sync_bin" -f "$evidence_dir/SHA256SUMS" || return 1
  "$sync_bin" -f "$evidence_dir" || return 1
}

persist_identity_report() {
  local report="$evidence_dir/postgres-identity.txt"
  {
    printf 'database=%s\nrole=%s\ncurrent_schema=%s\nconfigured_search_path=%s\n' \
      "$actual_database" "$actual_role" "$actual_schema" "$configured_search_path"
    printf 'role_superuser=%s\nrole_superuser_normalized=%s\npublic_schema_objects=%s\nlmm_meta_present=%s\nlmm_meta_present_normalized=%s\nlmm_meta_objects=%s\n' \
      "$actual_superuser" "$normalized_superuser" "$public_objects" "$lmm_meta_present" "$normalized_lmm_meta" "$lmm_meta_objects"
  } >"$report" || return 1
  chmod 0600 -- "$report" || return 1
  "$sync_bin" -f "$report" || return 1
}

identity_fail() {
  local reason=$1 failure="$evidence_dir/postgres-identity-failure.txt"
  printf '%s\n' "$reason" >"$failure" || die 'could not persist PostgreSQL identity failure'
  chmod 0600 -- "$failure" || die 'could not secure PostgreSQL identity failure'
  "$sync_bin" -f "$failure" || die 'could not durably persist PostgreSQL identity failure'
  die "$reason"
}

normalize_pg_bool() {
  case ${1,,} in
    f|false) printf 'f\n' ;;
    t|true) printf 't\n' ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local status=$? cleanup_failed=0
  trap - EXIT INT TERM
  stop_owned_pid "$valkey_pid" "$valkey_server_bin" Valkey || cleanup_failed=1
  stop_owned_pid "$postgres_pid" "$postgres_bin" PostgreSQL || cleanup_failed=1
  if [[ -n $short_socket_dir && -d $short_socket_dir && ! -L $short_socket_dir ]]; then
    rmdir -- "$short_socket_dir" 2>/dev/null || true
  fi
  if [[ -n $evidence_dir && -d $evidence_dir ]]; then
    if ((status == 0 && cleanup_failed == 0)); then
      write_final_status PASS || cleanup_failed=1
    else
      write_final_status FAIL || cleanup_failed=1
    fi
  fi
  if ((status == 0 && cleanup_failed != 0)); then status=1; fi
  exit "$status"
}

workspace=''; workspace_marker=''; transport=unix
initdb_arg=''; postgres_arg=''; psql_arg=''; valkey_server_arg=''; valkey_cli_arg=''
cargo_arg=''; ss_arg=''
sync_arg=''; sha256sum_arg=''
readonly EXPECTED_ADOPTION_TEST_SHA256=f180aa970ce514a893d5c86fcdebfa8704d20e1796f272c592d7870ee4379cd0
while (($#)); do
  case $1 in
    --workspace) (($# >= 2)) || usage; workspace=$2; shift 2 ;;
    --workspace-marker) (($# >= 2)) || usage; workspace_marker=$2; shift 2 ;;
    --transport) (($# >= 2)) || usage; transport=$2; shift 2 ;;
    --initdb) (($# >= 2)) || usage; initdb_arg=$2; shift 2 ;;
    --postgres) (($# >= 2)) || usage; postgres_arg=$2; shift 2 ;;
    --psql) (($# >= 2)) || usage; psql_arg=$2; shift 2 ;;
    --valkey-server) (($# >= 2)) || usage; valkey_server_arg=$2; shift 2 ;;
    --valkey-cli) (($# >= 2)) || usage; valkey_cli_arg=$2; shift 2 ;;
    --cargo) (($# >= 2)) || usage; cargo_arg=$2; shift 2 ;;
    --ss) (($# >= 2)) || usage; ss_arg=$2; shift 2 ;;
    --sync) (($# >= 2)) || usage; sync_arg=$2; shift 2 ;;
    --sha256sum) (($# >= 2)) || usage; sha256sum_arg=$2; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n $workspace && -n $workspace_marker ]] || usage
[[ $transport == unix || $transport == tcp ]] || die 'transport must be unix or tcp'
validate_workspace

initdb_bin=$(resolve_command initdb "$initdb_arg")
postgres_bin=$(resolve_command postgres "$postgres_arg")
psql_bin=$(resolve_command psql "$psql_arg")
valkey_server_bin=$(resolve_command valkey-server "$valkey_server_arg")
valkey_cli_bin=$(resolve_command valkey-cli "$valkey_cli_arg")
cargo_bin=$(resolve_cargo_command "$cargo_arg")
cargo_exec_bin=$(resolve_cargo_execution_path "$cargo_arg")
ss_bin=$(resolve_command ss "$ss_arg")
sync_bin=$(resolve_command sync "$sync_arg")
sha256sum_bin=$(resolve_command sha256sum "$sha256sum_arg")

pg_version=$($postgres_bin --version)
initdb_version=$($initdb_bin --version)
[[ $pg_version =~ PostgreSQL[^0-9]*18([.][0-9]+)?$ ]] || die 'postgres major version must be exactly 18'
[[ $initdb_version =~ PostgreSQL[^0-9]*18([.][0-9]+)?$ ]] || die 'initdb major version must be exactly 18'
valkey_version=$($valkey_server_bin --version)
valkey_cli_version=$($valkey_cli_bin --version)
[[ $valkey_version =~ Valkey[[:space:]]server[[:space:]]v=([0-9]+\.[0-9]+\.[0-9]+) ]] ||
  die 'could not verify Valkey server version'
verified_valkey_version=${BASH_REMATCH[1]}
[[ $valkey_cli_version =~ valkey-cli[[:space:]]([0-9]+\.[0-9]+\.[0-9]+) ]] ||
  die 'could not verify Valkey CLI version'
[[ ${BASH_REMATCH[1]} == "$verified_valkey_version" ]] || die 'Valkey server and CLI versions differ'

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)
manifest="$repo_root/apps/api-rust/Cargo.toml"
[[ $manifest == /* && -f $manifest && ! -L $manifest ]] || die 'absolute Cargo manifest is unavailable'
adoption_test_source="$repo_root/apps/api-rust/crates/lmm-db-migrate/tests/postgres_adopt_existing.rs"
[[ -f $adoption_test_source && ! -L $adoption_test_source ]] || die 'adoption integration test source is unavailable'
actual_adoption_test_sha256=$("$sha256sum_bin" -- "$adoption_test_source")
actual_adoption_test_sha256=${actual_adoption_test_sha256%% *}
[[ $actual_adoption_test_sha256 == "$EXPECTED_ADOPTION_TEST_SHA256" ]] ||
  die 'postgres_adopt_existing source digest changed; review and rebind the exact six-test target'
expected_tests=(
  adoption_should_commit_once_replay_without_writes_and_reject_partial_ledger
  catalog_lock_should_acquire_immediately_when_uncontended
  catalog_lock_should_time_out_when_contended
  catalog_lock_should_release_after_holder_rollback
  catalog_lock_should_release_after_holder_commit
  adoption_lock_timeout_should_not_create_ledger
)
mapfile -t actual_tests < <(awk '
  /^#\[test\]$/ { in_test=1; ignored=0; next }
  in_test && /^#\[ignore = / { ignored=1; next }
  in_test && /^fn [A-Za-z0-9_]+\(\)/ {
    if (ignored) { name=$2; sub(/\(.*/, "", name); print name }
    in_test=0; ignored=0
  }
' "$adoption_test_source")
[[ ${#actual_tests[@]} == 6 ]] || die 'postgres_adopt_existing must contain exactly six ignored integration tests'
for index in "${!expected_tests[@]}"; do
  [[ ${actual_tests[$index]} == "${expected_tests[$index]}" ]] ||
    die 'postgres_adopt_existing ignored test set changed; review the harness scope'
done

nonce=$(od -An -N12 -tx1 /dev/urandom | tr -d '[:space:]')
run_dir="$workspace/postgres-adoption-lock-$nonce"
[[ ! -e $run_dir && ! -L $run_dir ]] || die 'unique run directory already exists'
mkdir -m 0700 -- "$run_dir"
config_dir="$run_dir/config"
data_dir="$run_dir/data"
evidence_dir="$run_dir/evidence"
mkdir -m 0700 -- "$config_dir" "$data_dir" "$evidence_dir" "$run_dir/home" "$run_dir/tmp" "$run_dir/cargo-target"
postgres_pid=''; valkey_pid=''; short_socket_dir=''
pg_admin_password=''; pg_app_password=''; valkey_password=''; database_url=''; valkey_url=''
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pg_admin="lmm_admin_${nonce:0:12}"
pg_app="lmm_adopt_${nonce:0:12}"
pg_database="lmm_adopt_${nonce:0:12}"
pg_admin_password=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
pg_app_password=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
valkey_password=$(od -An -N24 -tx1 /dev/urandom | tr -d '[:space:]')
printf '%s\n' "$pg_admin_password" >"$config_dir/postgres-admin-password"
chmod 0600 -- "$config_dir/postgres-admin-password"

"$initdb_bin" --pgdata="$data_dir/postgres" --username="$pg_admin" \
  --pwfile="$config_dir/postgres-admin-password" --encoding=UTF8 --no-locale \
  --auth-local=scram-sha-256 --auth-host=scram-sha-256 >"$config_dir/initdb.log" 2>&1
if grep -Eq '(^|[[:space:]])trust([[:space:]]|$)' "$data_dir/postgres/pg_hba.conf"; then
  die 'PostgreSQL authentication unexpectedly contains trust'
fi

if [[ $transport == unix ]]; then
  runtime_parent="/run/user/$(id -u)"
  [[ -d $runtime_parent && ! -L $runtime_parent && $(stat -c %u -- "$runtime_parent") == "$EUID" ]] ||
    die 'private /run/user UID directory is required for unix transport; select --transport tcp explicitly to fall back'
  short_socket_dir=$(mktemp -d "$runtime_parent/lmm-a-XXXXXX")
  chmod 0700 -- "$short_socket_dir"
  pg_port=5432
  postgres_args=(-D "$data_dir/postgres" -c listen_addresses= -c "unix_socket_directories=$short_socket_dir" -p "$pg_port")
  pg_host=$short_socket_dir
  encoded_socket=${short_socket_dir//\//%2F}
  database_url="postgresql://$pg_app:$pg_app_password@/$pg_database?host=$encoded_socket&port=$pg_port&connect_timeout=5"
else
  pg_port=$(choose_tcp_port) || die 'could not select an unused PostgreSQL loopback port'
  valkey_port=$(choose_tcp_port) || die 'could not select an unused Valkey loopback port'
  while [[ $valkey_port == "$pg_port" ]]; do valkey_port=$(choose_tcp_port) || die 'could not select distinct loopback ports'; done
  postgres_args=(-D "$data_dir/postgres" -c listen_addresses=127.0.0.1 -p "$pg_port")
  pg_host=127.0.0.1
  database_url="postgresql://$pg_app:$pg_app_password@127.0.0.1:$pg_port/$pg_database"
fi

"$postgres_bin" "${postgres_args[@]}" >"$config_dir/postgres.log" 2>&1 &
postgres_pid=$!
pg_listener_ready=0
for _ in {1..200}; do
  kill -0 "$postgres_pid" 2>/dev/null || die 'PostgreSQL exited during startup'
  if pid_executable_is "$postgres_pid" "$postgres_bin"; then
    if [[ $transport == unix ]] && unix_listener_belongs_to_pid "$short_socket_dir/.s.PGSQL.$pg_port" "$postgres_pid"; then pg_listener_ready=1; break; fi
    if [[ $transport == tcp ]] && tcp_listener_belongs_to_pid "$pg_port" "$postgres_pid"; then pg_listener_ready=1; break; fi
  fi
  sleep 0.05
done
((pg_listener_ready == 1)) || die 'PostgreSQL listener identity could not be verified'
pgpass_file="$config_dir/pgpass"
printf '%s:%s:*:%s:%s\n%s:%s:%s:%s:%s\n' \
  "$pg_host" "$pg_port" "$pg_admin" "$pg_admin_password" \
  "$pg_host" "$pg_port" "$pg_database" "$pg_app" "$pg_app_password" >"$pgpass_file"
chmod 0600 -- "$pgpass_file"
admin_psql=(env "PGPASSFILE=$pgpass_file" "$psql_bin" -h "$pg_host" -p "$pg_port" -U "$pg_admin" -d postgres -v ON_ERROR_STOP=1)
app_psql=(env "PGPASSFILE=$pgpass_file" "$psql_bin" -h "$pg_host" -p "$pg_port" -U "$pg_app" -d "$pg_database" -v ON_ERROR_STOP=1)
postgres_ready=0
for _ in {1..200}; do
  if "${admin_psql[@]}" -Atqc 'SELECT 1' >/dev/null 2>&1; then
    postgres_ready=1
    break
  fi
  sleep 0.05
done
((postgres_ready == 1)) || die 'PostgreSQL readiness timed out before setup'

role_sql="$config_dir/create-role.sql"
database_sql="$config_dir/create-database.sql"
search_path_sql="$config_dir/set-search-path.sql"
printf "CREATE ROLE \"%s\" LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;\n" \
  "$pg_app" "$pg_app_password" >"$role_sql"
printf 'CREATE DATABASE "%s" OWNER "%s";\n' "$pg_database" "$pg_app" >"$database_sql"
printf 'ALTER ROLE "%s" IN DATABASE "%s" SET search_path = public;\n' "$pg_app" "$pg_database" >"$search_path_sql"
chmod 0600 -- "$role_sql" "$database_sql" "$search_path_sql"
"${admin_psql[@]}" -f "$role_sql" >/dev/null
"${admin_psql[@]}" -f "$database_sql" >/dev/null
"${admin_psql[@]}" -f "$search_path_sql" >/dev/null

configured_search_path='query-failed'
configured_search_path=$("${app_psql[@]}" -Atqc 'SHOW search_path' 2>/dev/null) || true
identity='|||||||'
identity=$("${app_psql[@]}" -Atqc \
  "SELECT current_database() || '|' || current_user || '|' || current_schema() || '|' || (SELECT rolsuper::text FROM pg_catalog.pg_roles WHERE rolname=current_user) || '|' || (SELECT count(*)::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public') || '|' || (SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname='lmm_meta')) || '|' || (SELECT count(*)::text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='lmm_meta')") || true
IFS='|' read -r actual_database actual_role actual_schema actual_superuser public_objects lmm_meta_present lmm_meta_objects <<<"$identity"
normalized_superuser=invalid
normalized_lmm_meta=invalid
if normalized_superuser=$(normalize_pg_bool "$actual_superuser"); then :; fi
if normalized_lmm_meta=$(normalize_pg_bool "$lmm_meta_present"); then :; fi
persist_identity_report || die 'could not durably persist PostgreSQL identity report'
[[ $configured_search_path == public ]] || identity_fail 'identity mismatch: configured_search_path must be exactly public'
[[ $actual_database == "$pg_database" ]] || identity_fail 'identity mismatch: current_database'
[[ $actual_role == "$pg_app" ]] || identity_fail 'identity mismatch: current_user'
[[ $actual_schema == public ]] || identity_fail 'identity mismatch: current_schema'
[[ $normalized_superuser == f ]] || identity_fail 'identity mismatch: role must be non-superuser'
[[ $public_objects == 0 ]] || identity_fail 'identity mismatch: public schema is not empty'
[[ $normalized_lmm_meta == f && $lmm_meta_objects == 0 ]] || identity_fail 'identity mismatch: lmm_meta must be absent and empty'

valkey_config="$config_dir/valkey.conf"
valkey_pidfile="$config_dir/valkey.pid"
if [[ $transport == unix ]]; then
  valkey_socket="$short_socket_dir/valkey.sock"
  printf 'bind 127.0.0.1\nport 0\nprotected-mode yes\ndaemonize no\npidfile %s\nunixsocket %s\nunixsocketperm 700\nsave ""\nappendonly no\ndir %s\nrequirepass %s\n' \
    "$valkey_pidfile" "$valkey_socket" "$data_dir" "$valkey_password" >"$valkey_config"
  valkey_url="redis+unix://$valkey_socket"
  valkey_cli_args=(-s "$valkey_socket")
else
  printf 'bind 127.0.0.1\nport %s\nprotected-mode yes\ndaemonize no\npidfile %s\nsave ""\nappendonly no\ndir %s\nrequirepass %s\n' \
    "$valkey_port" "$valkey_pidfile" "$data_dir" "$valkey_password" >"$valkey_config"
  valkey_url="redis://:$valkey_password@127.0.0.1:$valkey_port/0"
  valkey_cli_args=(-h 127.0.0.1 -p "$valkey_port")
fi
chmod 0600 -- "$valkey_config"
valkey_config_sha=$(sha256sum -- "$valkey_config")
valkey_config_sha=${valkey_config_sha%% *}
"$valkey_server_bin" "$valkey_config" >"$config_dir/valkey.log" 2>&1 &
valkey_pid=$!
valkey_listener_ready=0
for _ in {1..200}; do
  kill -0 "$valkey_pid" 2>/dev/null || die 'Valkey exited during startup'
  if pid_executable_is "$valkey_pid" "$valkey_server_bin"; then
    if [[ $transport == unix ]] && unix_listener_belongs_to_pid "$valkey_socket" "$valkey_pid"; then valkey_listener_ready=1; break; fi
    if [[ $transport == tcp ]] && tcp_listener_belongs_to_pid "$valkey_port" "$valkey_pid"; then valkey_listener_ready=1; break; fi
  fi
  sleep 0.05
done
((valkey_listener_ready == 1)) || die 'Valkey listener identity could not be verified'
[[ -f $valkey_pidfile && ! -L $valkey_pidfile && $(<"$valkey_pidfile") == "$valkey_pid" ]] ||
  die 'Valkey pidfile identity check failed'
current_valkey_sha=$(sha256sum -- "$valkey_config")
current_valkey_sha=${current_valkey_sha%% *}
[[ $current_valkey_sha == "$valkey_config_sha" ]] || die 'Valkey configuration changed after startup'
if "$valkey_cli_bin" -e --no-auth-warning "${valkey_cli_args[@]}" ping >/dev/null 2>&1; then
  die 'Valkey accepted an unauthenticated request'
fi
VALKEYCLI_AUTH="$valkey_password" "$valkey_cli_bin" --no-auth-warning "${valkey_cli_args[@]}" ping |
  grep -Fqx PONG || die 'authenticated Valkey identity check failed'

{
  printf 'postgres_version=%s\n' "$pg_version"
  printf 'valkey_version=%s\n' "$verified_valkey_version"
  printf 'transport=%s\n' "$transport"
  printf 'database=%s\nrole=%s\nrole_superuser=false\npublic_schema_objects=0\n' "$pg_database" "$pg_app"
  printf 'configured_search_path=public\nignored_adoption_tests=6\n'
  printf 'postgres_pid_verified=true\nvalkey_pidfile_verified=true\nvalkey_executable_verified=true\n'
  cargo_hash=$($sha256sum_bin -- "$cargo_bin")
  cargo_hash=${cargo_hash%% *}
  printf 'valkey_listener_verified=true\nvalkey_auth_verified=true\nvalkey_config_sha256=%s\n' "$valkey_config_sha"
  printf 'cargo_resolved_target=%s\ncargo_resolved_sha256=%s\n' "$cargo_bin" "$cargo_hash"
} >"$evidence_dir/checks.txt"
chmod 0600 -- "$evidence_dir/checks.txt"

cargo_log="$evidence_dir/cargo.log"
contract_fake_root=${LMM_ADOPTION_CONTRACT_FAKE_ROOT:-}
contract_cargo_exit_at=${LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT:-}
cargo_home_value=${CARGO_HOME:-$HOME/.cargo}
rustup_home_value=${RUSTUP_HOME:-$HOME/.rustup}
# DATABASE_URL is required by the Rust test process. It exists only in this
# command environment and is never placed in shell argv or a raw log. Like any
# same-UID child environment it is necessarily visible through /proc/PID/environ.
: >"$cargo_log"
chmod 0600 -- "$cargo_log"
cargo_status=0
cargo_index=0
for test_name in "${expected_tests[@]}"; do
  ((cargo_index += 1))
  current_source_sha=$("$sha256sum_bin" -- "$adoption_test_source")
  current_source_sha=${current_source_sha%% *}
  [[ $current_source_sha == "$EXPECTED_ADOPTION_TEST_SHA256" ]] ||
    die 'postgres_adopt_existing source changed before an exact test invocation'
  set +e
  (
    set +x
    while IFS= read -r inherited_name; do unset "$inherited_name"; done < <(compgen -e)
    if [[ -n $contract_fake_root ]]; then
      PATH=/usr/bin:/bin HOME="$run_dir/home" TMPDIR="$run_dir/tmp" \
        CARGO_HOME="$cargo_home_value" RUSTUP_HOME="$rustup_home_value" CARGO_TARGET_DIR="$run_dir/cargo-target" RUST_BACKTRACE=1 \
        FAKE_ROOT="$contract_fake_root" LMM_ADOPTION_CONTRACT_CARGO_EXIT_AT="$contract_cargo_exit_at" \
        LMM_ADOPTION_CONTRACT_CARGO_INDEX="$cargo_index" \
        LMM_TEST_ADOPT_DATABASE_URL="$database_url" \
        "$cargo_exec_bin" test --locked --manifest-path "$manifest" --package lmm-db-migrate \
          --test postgres_adopt_existing -- "$test_name" --ignored --exact --test-threads=1
    else
      PATH=/usr/bin:/bin HOME="$run_dir/home" TMPDIR="$run_dir/tmp" \
        CARGO_HOME="$cargo_home_value" RUSTUP_HOME="$rustup_home_value" CARGO_TARGET_DIR="$run_dir/cargo-target" RUST_BACKTRACE=1 \
        LMM_TEST_ADOPT_DATABASE_URL="$database_url" \
        "$cargo_exec_bin" test --locked --manifest-path "$manifest" --package lmm-db-migrate \
          --test postgres_adopt_existing -- "$test_name" --ignored --exact --test-threads=1
    fi
  ) 2>&1 | redact_stream >>"$cargo_log"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if ((pipeline_status[1] != 0)); then cargo_status=${pipeline_status[1]}; break; fi
  if ((pipeline_status[0] != 0)); then cargo_status=${pipeline_status[0]}; break; fi
  current_source_sha=$("$sha256sum_bin" -- "$adoption_test_source")
  current_source_sha=${current_source_sha%% *}
  [[ $current_source_sha == "$EXPECTED_ADOPTION_TEST_SHA256" ]] ||
    die 'postgres_adopt_existing source changed after an exact test invocation'
done
final_source_sha=$("$sha256sum_bin" -- "$adoption_test_source")
final_source_sha=${final_source_sha%% *}
[[ $final_source_sha == "$EXPECTED_ADOPTION_TEST_SHA256" ]] ||
  die 'postgres_adopt_existing source changed after the exact six-test gate'
(
  cd -- "$evidence_dir"
  sha256sum -- checks.txt cargo.log >SHA256SUMS
)
chmod 0600 -- "$evidence_dir/SHA256SUMS"
sync_evidence || die 'could not durably synchronize sanitized evidence'
if ((cargo_status != 0)); then
  printf 'postgres-adoption-lock-gates: exact Cargo test failed with status %s; sanitized evidence: %s\n' \
    "$cargo_status" "$evidence_dir" >&2
  exit "$cargo_status"
fi

printf 'PostgreSQL adoption lock gates passed; sanitized evidence: %s\n' "$evidence_dir"
