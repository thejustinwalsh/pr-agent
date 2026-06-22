#!/usr/bin/env bats
setup() {
  TMP="$(mktemp -d)"
  cat > "$TMP/vars" <<'EOF'
CF_SERVICE_TOKEN_ID=tid
CF_SERVICE_TOKEN_SECRET=tsec
FORK_REPO=thejustinwalsh/pr-agent
TUNNEL_ID=abc-123
EOF
}
teardown() { rm -rf "$TMP"; }

@test "renders, substitutes vars, and stays under 32 KiB" {
  run bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  [ "$status" -eq 0 ]
  [ "$(wc -c < "$TMP/out.yaml")" -lt 32768 ]
  ! grep -q "__" "$TMP/out.yaml"        # no leftover placeholders
  grep -q "tid" "$TMP/out.yaml"
}

@test "output is valid cloud-init/YAML" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  run yamllint -d relaxed "$TMP/out.yaml"
  [ "$status" -eq 0 ]
}

@test "enables linger for the deploy user" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "enable-linger pragent" "$TMP/out.yaml"
}

@test "installs quadlet units and timers into the right XDG paths" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q '\.config/containers/systemd' "$TMP/out.yaml"   # *.pod *.container
  grep -q '\.config/systemd/user' "$TMP/out.yaml"         # *.timer *.service
  grep -q "pr-agent-deploy.timer" "$TMP/out.yaml"
  grep -q "pr-agent-prune.timer" "$TMP/out.yaml"
}

@test "ufw allows 22/tcp and never uses --force on allow/default" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "ufw allow 22/tcp" "$TMP/out.yaml"
  grep -q "ufw default deny incoming" "$TMP/out.yaml"
  grep -q "ufw --force enable" "$TMP/out.yaml"
  ! grep -qE "ufw --force (allow|default)" "$TMP/out.yaml"
}

@test "sshd hardening drop-in is present (key-only, root via key)" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "/etc/ssh/sshd_config.d/00-pragent.conf" "$TMP/out.yaml"
  grep -q "PermitRootLogin prohibit-password" "$TMP/out.yaml"
  grep -q "PasswordAuthentication no" "$TMP/out.yaml"
  grep -q "PubkeyAuthentication yes" "$TMP/out.yaml"
}

@test "installs openssh-server and the rootless podman stack (no sqlite3)" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "openssh-server" "$TMP/out.yaml"
  grep -q "uidmap" "$TMP/out.yaml"
  grep -q "slirp4netns" "$TMP/out.yaml"
  grep -q "fail2ban" "$TMP/out.yaml"
  ! grep -q "sqlite3" "$TMP/out.yaml"
}

@test "chmod +x safety net for deploy and patch scripts is present" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "chmod +x ~/pr-agent/deploy/\*.sh ~/pr-agent/patches/\*.sh" "$TMP/out.yaml"
}

@test "preserves platform key injection and clones the fork's production branch" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  grep -q "  - default" "$TMP/out.yaml"   # keep the distro/Hetzner default user
  grep -q "git clone -b production https://github.com/thejustinwalsh/pr-agent.git ~/pr-agent" "$TMP/out.yaml"
  grep -q "/home/pragent/.ssh/authorized_keys" "$TMP/out.yaml"
}

@test "is stateless — no Hetzner volume / mkfs block" {
  bash "$BATS_TEST_DIRNAME/../gen-cloud-init.sh" "$TMP/vars" "$TMP/out.yaml"
  ! grep -q "mkfs" "$TMP/out.yaml"
  ! grep -q "blkid" "$TMP/out.yaml"
  ! grep -q "HC_Volume" "$TMP/out.yaml"
}
