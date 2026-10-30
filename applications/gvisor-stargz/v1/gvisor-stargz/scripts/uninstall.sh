#!/usr/bin/env bash
# Removes the combined runsc-stargz handler and the gvisor-stargz
# RuntimeClass registered by install.sh. Keeps the gvisor and stargz
# installations untouched.
set -euo pipefail

log() { printf '[gvisor-stargz] %s\n' "$*"; }
warn() { printf '[gvisor-stargz] WARN: %s\n' "$*" >&2; }
die() { printf '[gvisor-stargz] ERROR: %s\n' "$*" >&2; exit 1; }

cfg=/etc/containerd/config.toml
runsc_root=${GVISOR_ROOT:-/run/containerd/runsc}

[[ $(id -u) -eq 0 ]] || die 'must run as root'
command -v systemctl >/dev/null || die 'systemctl not found'

if [[ -x /usr/local/bin/runsc ]] && command -v timeout >/dev/null; then
  count=$(timeout 10 /usr/local/bin/runsc --root="$runsc_root/k8s.io" list 2>/dev/null | grep -c RUNNING || true)
  [[ $count -eq 0 ]] || die "$count running gVisor sandbox(es); stop them (delete the pods) before removing the handler"
fi

if [[ -f $cfg ]]; then
  tmp=$(mktemp)
  awk '
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc-stargz(\]|\.options\])[[:space:]]*$/ { skip=1; next }
    /^[[:space:]]*\[/ { skip=0 }
    skip { next }
    { print }
  ' "$cfg" >"$tmp"
  if ! cmp -s "$tmp" "$cfg"; then
    install -m 644 "$tmp" "$cfg"
    log 'removed runsc-stargz handler blocks from containerd config'
  fi
  rm -f "$tmp"
  containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the cleaned configuration'
fi

systemctl restart containerd
systemctl is-active --quiet containerd || die 'containerd is not active'

if command -v kubectl >/dev/null 2>&1; then
  kubectl delete runtimeclass gvisor-stargz --ignore-not-found || true
fi

log 'combined runtime handler removed; gvisor and stargz installations untouched'
