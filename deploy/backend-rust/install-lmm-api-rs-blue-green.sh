#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly HERE
grep -Fq 'include /etc/nginx/snippets/lmm-api-rs-probe-locations.conf;' /etc/nginx/conf.d/new-api.conf || {
    echo "install the repository-managed nginx split before the Rust backend layout" >&2
    exit 1
}

install -d -m 0755 /opt/lmm-api-rs/releases /opt/lmm-api-rs/slots/blue /opt/lmm-api-rs/slots/green
install -d -m 0750 -o lmm-api-rs -g lmm-api-rs /var/lib/lmm-api-rs
install -d -m 0700 /etc/lmm-api-rs /var/log/lmm-api-rs/deployments
install -d -m 0755 /usr/lib/lmm-api-rs/deploy/nginx
install -m 0755 "$HERE/deploy-lmm-api-rs.sh" /usr/lib/lmm-api-rs/deploy/deploy-lmm-api-rs.sh
install -m 0755 "$HERE/install-nginx-rust-routing.sh" /usr/lib/lmm-api-rs/deploy/install-nginx-rust-routing.sh
install -m 0644 "$HERE/nginx/lmm-api-rs-probe-locations.conf" /usr/lib/lmm-api-rs/deploy/nginx/lmm-api-rs-probe-locations.conf
install -m 0644 "$HERE/nginx/lmm-api-rs-upstream.conf" /usr/lib/lmm-api-rs/deploy/nginx/lmm-api-rs-upstream.conf
install -m 0644 "$HERE/../nginx/new-api.conf" /usr/lib/lmm-api-rs/deploy/nginx/new-api.conf
install -m 0644 "$HERE/lmm-api-rs@.service" /etc/systemd/system/lmm-api-rs@.service
install -m 0600 "$HERE/blue.env" /etc/lmm-api-rs/blue.env
install -m 0600 "$HERE/green.env" /etc/lmm-api-rs/green.env
if [[ ! -e /etc/lmm-api-rs/common.env ]]; then
    install -m 0600 "$HERE/common.env.example" /etc/lmm-api-rs/common.env.example
fi
install -m 0600 "$HERE/deploy.conf.example" /etc/lmm-api-rs/deploy.conf.example
ln -sfn /usr/lib/lmm-api-rs/deploy/deploy-lmm-api-rs.sh /usr/local/sbin/deploy-lmm-api-rs
ln -sfn /usr/lib/lmm-api-rs/deploy/install-nginx-rust-routing.sh /usr/local/sbin/install-nginx-rust-routing
systemctl daemon-reload

echo "Installed fixed deployment layout. Populate common.env, then bootstrap nginx routing before the first deploy."
