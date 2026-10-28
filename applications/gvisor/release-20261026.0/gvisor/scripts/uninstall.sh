#!/usr/bin/env bash
# Removes the gVisor runtime installed by install.sh: binaries, config
# files, containerd handler blocks and the optional metrics service.
# Sandboxes using the `runsc` handler must be stopped first; this script
# refuses to remove the runtime while running sandboxes exist.
set -euo pipefail

log() { printf '[gvisor] %s\n' "$*"; }
warn() { printf '[gvisor] WARN: %s\n' "$*" >&2; }
die() { printf '[gvisor] ERROR: %s\n' "$*" >&2; exit 1; }

cfg=/etc/containerd/config.toml
runsc_toml=/etc/containerd/runsc.toml
bin_dir=/usr/local/bin
root_dir=${GVISOR_ROOT:-/run/containerd/runsc}

[[ $(id -u) -eq 0 ]] || die 'must run as root'
command -v systemctl >/dev/null || die 'systemctl not found'

if [[ -x $bin_dir/runsc ]] && command -v timeout >/dev/null; then
  count=$(timeout 10 "$bin_dir/runsc" --root="$root_dir/k8s.io" list 2>/dev/null | grep -c RUNNING || true)
  [[ $count -eq 0 ]] || die "$count running gVisor sandbox(es); stop them (delete the pods) before uninstalling"
fi

if [[ -f $cfg ]]; then
  tmp=$(mktemp)
  awk '
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc(\]|\.options\])[[:space:]]*$/ { skip=1; next }
    /^[[:space:]]*\[/ { skip=0 }
    skip { next }
    { print }
  ' "$cfg" >"$tmp"
  if ! cmp -s "$tmp" "$cfg"; then
    install -m 644 "$tmp" "$cfg"
    log 'removed runsc handler blocks from containerd config'
  fi
  rm -f "$tmp"
  containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the cleaned configuration'
fi

systemctl disable --now gvisor-metrics >/dev/null 2>&1 || true
rm -f /etc/systemd/system/gvisor-metrics.service

rm -f "$runsc_toml" "$bin_dir/runsc" "$bin_dir/containerd-shim-runsc-v1"
rm -rf "$bin_dir/gvisor-bin"

systemctl daemon-reload
systemctl restart containerd
systemctl is-active --quiet containerd || die 'containerd is not active'

if command -v kubectl >/dev/null 2>&1; then
  kubectl delete runtimeclass gvisor --ignore-not-found || true
fi

log 'gVisor runtime removed; backups remain under /var/backups/sealos-gvisor'
