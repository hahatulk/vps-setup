#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() {
  echo "OK: $*"
}

echo "== Bash syntax =="
files=(install.sh uninstall.sh lib/common.sh lib/verify-crl-health lib/pve-openvpn-fw lib/pve-openvpn-render-server)
while IFS= read -r f; do
  files+=("$f")
done < <(find bin -maxdepth 1 -type f -name 'ovpn*' -print | sort)

bash -n "${files[@]}" || fail "bash -n"
ok "bash syntax"

echo
echo "== Common library =="
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

[[ "$(normalize_cidr 10.8.0.17/24)" == "10.8.0.0/24" ]] || fail "normalize_cidr"
[[ "$(normalize_cidr 192.168.50.123/26)" == "192.168.50.64/26" ]] || fail "normalize /26"
cidr_overlap 10.8.0.0/24 10.8.0.128/25 || fail "overlap true"
if cidr_overlap 10.8.0.0/24 10.9.0.0/24; then fail "overlap false"; fi
validate_endpoint vpn.example.com
validate_endpoint 203.0.113.10
[[ "$(openvpn_server_proto udp)" == "udp" ]] || fail "UDP server proto mapping"
[[ "$(openvpn_client_proto udp)" == "udp" ]] || fail "UDP client proto mapping"
[[ "$(openvpn_server_proto tcp)" == "tcp-server" ]] || fail "TCP server proto mapping"
[[ "$(openvpn_client_proto tcp)" == "tcp-client" ]] || fail "TCP client proto mapping"
if openvpn_server_proto invalid >/dev/null 2>&1; then fail "invalid server proto accepted"; fi
if openvpn_client_proto invalid >/dev/null 2>&1; then fail "invalid client proto accepted"; fi
ok "CIDR/endpoint/proto validation"

echo
echo "== Interactive ovpn policy =="
for f in bin/ovpn bin/ovpn-add-client bin/ovpn-list-clients bin/ovpn-restart \
         bin/ovpn-revoke-client bin/ovpn-scrub-client-secret bin/ovpn-set-mode \
         bin/ovpn-set-proto bin/ovpn-upload-nextcloud bin/ovpn-status; do
  [[ -f "$f" ]] || fail "missing $f"
  grep -Fq '($# == 0)' "$f" || fail "$f does not explicitly reject arguments"
  grep -Fq 'require_interactive_tty' "$f" || fail "$f is not explicitly interactive/TTY-only"
done
[[ ! -e bin/ovpn-fw ]] || fail "internal firewall helper leaked into user-facing bin/"
[[ ! -e bin/ovpn-render-server ]] || fail "internal render helper leaked into user-facing bin/"
ok "ovpn commands are zero-argument user interfaces"

echo
echo "== Nextcloud uploader safety =="
uploader="bin/ovpn-upload-nextcloud"
grep -Fq "X-Requested-With: XMLHttpRequest" "$uploader" || fail "Nextcloud uploader misses X-Requested-With"
grep -Fq "X-NC-Nickname:" "$uploader" || fail "Nextcloud uploader misses X-NC-Nickname"
grep -Fq "Public-share токен" "$uploader" || fail "Nextcloud uploader token prompt missing"
grep -Fq "read -r -s" "$uploader" || fail "Nextcloud uploader secrets are not hidden"
grep -Fq 'curl --config "$CURL_URL_CONFIG"' "$uploader" || fail "Nextcloud token URL is not passed through temp curl config"
grep -Fq "HTTP 200" README.md || fail "Nextcloud success codes are not documented"

urlencode_fn="$(
  awk '
    /^urlencode_segment\(\) \{/ {capture=1}
    capture {print}
    capture && /^\}$/ {exit}
  ' "$uploader"
)"
[[ -n "$urlencode_fn" ]] || fail "cannot extract urlencode_segment"
eval "$urlencode_fn"
encoded="$(urlencode_segment 'тест файл.txt')"
[[ "$encoded" == '%D1%82%D0%B5%D1%81%D1%82%20%D1%84%D0%B0%D0%B9%D0%BB.txt' ]] ||
  fail "UTF-8 URL encoding: $encoded"
ok "Nextcloud headers/secrets/UTF-8 encoding"

echo
echo "== Installer update-only ordering =="
update_line="$(grep -n 'if managed_install_present; then' install.sh | head -n1 | cut -d: -f1)"
prompt_line="$(grep -n 'if (( INTERACTIVE_INSTALL )); then' install.sh | head -n1 | cut -d: -f1)"
apt_line="$(grep -n 'apt-get update' install.sh | head -n1 | cut -d: -f1)"
[[ "$update_line" =~ ^[0-9]+$ && "$prompt_line" =~ ^[0-9]+$ && "$apt_line" =~ ^[0-9]+$ ]] ||
  fail "cannot locate update/prompt/apt sections"
(( update_line < prompt_line && update_line < apt_line )) ||
  fail "managed update-only path must run before prompts and apt"
grep -Fq 'update_tooling_only update' install.sh || fail "missing update-only tooling call"
grep -Fq 'update_tooling_only initial' install.sh || fail "missing initial tooling call"
ok "existing managed install updates tooling before prompts/apt"

echo
echo "== PKI example / Git safety =="
for expected in   pki-example/README.md   pki-example/pki/README.md   pki-example/pki/vars.example   pki-example/pki/private/.gitkeep   pki-example/pki/issued/.gitkeep   pki-example/pki/reqs/.gitkeep   pki-example/pki/certs_by_serial/.gitkeep   pki-example/pki/revoked/.gitkeep   pki-example/pki/inline/.gitkeep   pki-example/pki/tls-crypt-v2-clients/.gitkeep   pki-example/pki/secret-scrubbed/.gitkeep; do
  [[ -e "$expected" ]] || fail "missing PKI placeholder $expected"
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Nonexistent paths are intentional: git check-ignore can validate the policy.
  for secret in     pki/private/ca.key     pki-example/pki/private/ca.key     pki-example/pki/issued/server.crt     pki-example/pki/crl.pem     pki-example/pki/index.txt     clients/test.ovpn; do
    git check-ignore -q -- "$ROOT/$secret" || fail "Git would not ignore secret path: $secret"
  done

  module_rel="$(git -C "$ROOT" ls-files --full-name . | sed -n '1s#/[^/]*$##p')"
  [[ -n "$module_rel" ]] || module_rel="openvpn"

  tracked_secrets="$(
    git -C "$ROOT" ls-files --full-name . |
      grep -E '\.(key|ovpn|p12|pfx|pkcs12|pem|csr|req|crt)$|/(index\.txt([^/]*)?|serial(\.old)?|crlnumber(\.old)?|crl\.pem)$' || true
  )"
  [[ -z "$tracked_secrets" ]] || {
    echo "$tracked_secrets" >&2
    fail "tracked secret-like PKI files found"
  }
  ok "Git secret ignore policy"
else
  echo "SKIP: not inside a Git worktree"
fi

echo
echo "All self-tests passed."
