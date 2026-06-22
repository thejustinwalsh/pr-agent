#!/usr/bin/env bash
# Cloud-init INTEGRATION test (the end-to-end verification, WS-I).
#
# Boots a fresh OrbStack Ubuntu machine with the REAL rendered cloud-init as
# user-data, waits for cloud-init to finish, and asserts the host ended up
# correctly provisioned. This executes the actual runcmd/write_files end-to-end —
# catching the class of bugs (ufw syntax, sshd hardening, user/linger, clone,
# unit install, lost +x bit) that the unit tier (yamllint/render/<32KiB) cannot.
#
# Requires: OrbStack (`orb`/`orbctl`). Run from anywhere: bash deploy/tests/cloud-init-integration.sh
#
# Notes / scope:
#  - fetch-secrets.sh and deploy.sh need a live Cloudflare broker + ghcr; with the
#    dummy token here they fail gracefully (cloud-init continues, deploy.sh runs
#    under `|| true`). This test verifies HOST PROVISIONING. The pod/app bring-up
#    is validated separately against real images (see DECISIONS-LOG).
#  - PR-Agent is STATELESS: there is no detachable volume and no mkfs. This test
#    asserts the rendered cloud-init carries no volume/mkfs block.
#  - SSH key injection is distro/Hetzner-specific; OrbStack injects no cloud-init
#    SSH key, so we assert statically that the `users:` block keeps `- default`
#    (preserving platform key injection) and that the key-copy to pragent is present.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MACHINE="${1:-pr-agent-ci-verify}"
IMAGE="${CI_IMAGE:-ubuntu:26.04}"

vars="$(mktemp)"; out="$(mktemp -t ci-XXXX).yaml"
trap 'rm -f "$vars" "$out"; orbctl delete -f "$MACHINE" >/dev/null 2>&1 || true' EXIT
cat > "$vars" <<EOF
CF_SERVICE_TOKEN_ID=dummy.access
CF_SERVICE_TOKEN_SECRET=dummy
FORK_REPO=thejustinwalsh/pr-agent
TUNNEL_ID=00000000-0000-0000-0000-000000000000
EOF
bash "$ROOT/deploy/gen-cloud-init.sh" "$vars" "$out" >/dev/null

orbctl delete -f "$MACHINE" >/dev/null 2>&1 || true
echo "[ci-int] booting $MACHINE ($IMAGE) with rendered cloud-init..."
orb create "$IMAGE" "$MACHINE" -c "$out"
orb -m "$MACHINE" -u root cloud-init status --wait >/dev/null 2>&1 || true

fail=0
check() { # name  remote-test-command
  if orb -m "$MACHINE" -u root bash -c "$2" >/dev/null 2>&1; then
    echo "  PASS  $1"
  else
    echo "  FAIL  $1"; fail=1
  fi
}
checkfile() { # name  grep-pattern   (static check: pattern present in rendered cloud-init)
  if grep -qF -- "$2" "$out"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi
}
checknotfile() { # name  grep-pattern   (static check: pattern ABSENT from rendered cloud-init)
  if grep -qiE -- "$2" "$out"; then echo "  FAIL  $1"; fail=1; else echo "  PASS  $1"; fi
}
echo "[ci-int] asserting host state (effective config on the booted machine):"
check "ufw allows 22/tcp"                 "ufw status | grep -qE '22/tcp .*ALLOW'"
# sshd -T prints the EFFECTIVE merged config (handles sshd_config.d/*.conf drop-ins).
check "sshd permitrootlogin prohibit-pw"  "sshd -T 2>/dev/null | grep -qi '^permitrootlogin prohibit-password'"
check "sshd passwordauthentication no"    "sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'"
check "fail2ban active"                   "systemctl is-active --quiet fail2ban"
check "pragent user exists"               "id pragent"
check "linger enabled for pragent"        "loginctl show-user pragent -p Linger 2>/dev/null | grep -q Linger=yes"
check "repo cloned (production)"          "test -d /home/pragent/pr-agent/deploy"
check "deploy scripts are executable"     "test -x /home/pragent/pr-agent/deploy/fetch-secrets.sh && test -x /home/pragent/pr-agent/deploy/deploy.sh && test -x /home/pragent/pr-agent/deploy/render-config.sh"
check "quadlet container unit installed"  "test -f /home/pragent/.config/containers/systemd/pr-agent.container"
check "deploy timer unit present"         "test -f /home/pragent/.config/systemd/user/pr-agent-deploy.timer"

echo "[ci-int] asserting key mechanism + stateless invariant (static — on the rendered file):"
checkfile "users: includes '- default' (preserves platform key injection)"  "- default"
checkfile "key-copy to /home/pragent/.ssh present"                           "/home/pragent/.ssh/authorized_keys"
# Stateless: PR-Agent has no detachable volume, so there must be no filesystem-format
# step. mkfs on a wrong device is destructive — assert the block never crept back in.
checknotfile "no volume/mkfs block (stateless)"                              "mkfs|mount /dev/"

if [ "$fail" -eq 0 ]; then echo "[ci-int] ALL CHECKS PASSED"; else echo "[ci-int] FAILURES ABOVE"; fi
exit "$fail"
