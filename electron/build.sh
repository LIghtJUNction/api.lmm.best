#!/usr/bin/env bash
set -euo pipefail

echo "Electron embedded-backend packaging is retired." >&2
echo "LMM API now requires the Rust service with external PostgreSQL and Valkey." >&2
echo "Use the Rust release bundle or container deployment instead." >&2
exit 1
