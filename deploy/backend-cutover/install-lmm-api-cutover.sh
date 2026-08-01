#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ ${1:-} == --migrator && $# == 2 ]] || { echo "usage: ${0##*/} --migrator /absolute/path/lmm-db-migrate" >&2; exit 1; }
MIGRATOR_SOURCE=$2
[[ $MIGRATOR_SOURCE == /* && -f $MIGRATOR_SOURCE && ! -L $MIGRATOR_SOURCE ]] || { echo "migrator must be an absolute regular file" >&2; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
RUST_ROOT=$(cd "$HERE/../../rust" && pwd)
readonly RUST_ROOT
install -d -m 0755 /run/lock
exec 9>/run/lock/lmm-api-backend-cutover.lock
flock -n 9 || { echo "another backend cutover or installer is running" >&2; exit 1; }

install -d -m 0700 /etc/lmm-api-cutover /var/lib/lmm-api-cutover/artifacts \
  /var/lib/lmm-api-cutover/sqlite-backups /var/log/lmm-api-cutover
install -d -m 0755 /usr/lib/lmm-api-cutover/schema
install -m 0755 "$HERE/cutover-sqlite-to-pg.sh" /usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh
install -m 0755 "$HERE/prepare-candidate-env.sh" /usr/lib/lmm-api-cutover/prepare-candidate-env.sh
install -m 0644 "$RUST_ROOT/crates/lmm-db-migrate/schema/table-map.json" /usr/lib/lmm-api-cutover/schema/table-map.json
install -m 0644 "$RUST_ROOT/crates/lmm-db-migrate/schema/postgresql-baseline.sql" /usr/lib/lmm-api-cutover/schema/postgresql-baseline.sql
install -m 0644 "$RUST_ROOT/crates/lmm-db-migrate/schema/export-postgres-catalog.sql" /usr/lib/lmm-api-cutover/schema/export-postgres-catalog.sql
install -m 0755 "$MIGRATOR_SOURCE" /usr/lib/lmm-api-cutover/lmm-db-migrate
install -m 0600 "$HERE/cutover.conf.example" /etc/lmm-api-cutover/cutover.conf.example
install -m 0600 "$HERE/migration.env.example" /etc/lmm-api-cutover/migration.env.example
ln -sfn /usr/lib/lmm-api-cutover/cutover-sqlite-to-pg.sh /usr/local/sbin/lmm-api-cutover
ln -sfn /usr/lib/lmm-api-cutover/prepare-candidate-env.sh /usr/local/sbin/lmm-api-prepare-cutover-env
echo "Installed cutover assets. Populate candidate env, migration.env, cutover.conf, and a fresh admin canary token before dry-run."
