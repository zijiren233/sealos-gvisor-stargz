#!/usr/bin/env bash
# Removes the stargz-snapshotter installed by install.sh: binaries,
# services, config files and containerd handler blocks. Snapshot data
# under the stargz root is preserved unless --purge-data is given.
#
# WARNING: containers whose images were pulled through the stargz
# snapshotter hold FUSE mounts backed by the snapshotter. Stop or
# migrate those workloads before uninstalling.
set -euo pipefail

log() { printf '[stargz] %s\n' "$*"; }
warn() { printf '[stargz] WARN: %s\n' "$*" >&2; }
die() { printf '[stargz] ERROR: %s\n' "$*" >&2; exit 1; }

cfg=/etc/containerd/config.toml
shim_cfg=/etc/image-cri-shim.yaml
stargz_service=stargz-snapshotter.service
bin_dir=/usr/local/bin
stargz_root=${STARGZ_ROOT:-/var/lib/containerd-stargz-grpc}
run_dir=${STARGZ_RUN_DIR:-/run/containerd-stargz-grpc}
purge_data=false
[[ ${1:-} == --purge-data ]] && purge_data=true

# State on the node wins over env defaults, mirroring install.sh.
if [[ -f /etc/containerd-stargz-grpc/config.toml ]]; then
  state_root=$(sed -nE 's/^[[:space:]]*root[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' /etc/containerd-stargz-grpc/config.toml | head -n1)
  state_addr=$(sed -nE 's/^[[:space:]]*address[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' /etc/containerd-stargz-grpc/config.toml | head -n1)
  [[ -n $state_root ]] && stargz_root=$state_root
  [[ -n $state_addr ]] && run_dir=$(dirname "$state_addr")
fi

[[ $(id -u) -eq 0 ]] || die 'must run as root'
command -v systemctl >/dev/null || die 'systemctl not found'

if systemctl is-active --quiet "$stargz_service"; then
  log 'stopping snapshotter (KillMode=process keeps the FUSE manager and its mounts alive)'
  systemctl stop "$stargz_service"
fi
# KillMode=process deliberately leaves the FUSE manager (and its mounts)
# alive across service restarts; an uninstall removes everything, so the
# manager must go too — mounts it holds die with it, as warned above.
# (-f: the process name exceeds the 15-char comm limit; the bracket
# pattern keeps pkill from matching its own command line.)
if pgrep -f '[s]targz-fuse-manager' >/dev/null 2>&1; then
  pkill -f '[s]targz-fuse-manager' || true
  log 'stopped the leftover stargz-fuse-manager'
fi

# Point image-cri-shim back at containerd if this image rewired it.
if [[ -f $shim_cfg ]] && grep -Eq "^cri:[[:space:]]*$run_dir/cri\.sock[[:space:]]*\$" "$shim_cfg"; then
  sed -i -E "s#^cri:[[:space:]]*$run_dir/cri\.sock[[:space:]]*\$#cri: /run/containerd/containerd.sock#" "$shim_cfg"
  log 'image-cri-shim cri endpoint restored to /run/containerd/containerd.sock'
fi

if [[ -f $cfg ]]; then
  tmp=$(mktemp)
  awk '
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.stargz(\]|\.options\])[[:space:]]*$/ { skip=1; next }
    /^[[:space:]]*\[proxy_plugins\.stargz(\]|\.exports\])[[:space:]]*$/ { skip=1; next }
    /^[[:space:]]*\[/ { skip=0 }
    skip { next }
    { print }
  ' "$cfg" >"$tmp"
  if ! cmp -s "$tmp" "$cfg"; then
    install -m 644 "$tmp" "$cfg"
    log 'removed stargz handler and proxy plugin blocks from containerd config'
  fi
  rm -f "$tmp"
  containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the cleaned configuration'
fi

systemctl disable "$stargz_service" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/$stargz_service" \
  /etc/systemd/system/containerd.service.d/20-stargz.conf \
  /etc/systemd/system/image-cri-shim.service.d/20-stargz.conf \
  /etc/logrotate.d/stargz-snapshotter
rm -rf /etc/containerd-stargz-grpc
rm -f "$bin_dir/containerd-stargz-grpc" "$bin_dir/stargz-fuse-manager" "$bin_dir/ctr-remote"
rmdir --ignore-fail-on-non-empty /etc/systemd/system/containerd.service.d /etc/systemd/system/image-cri-shim.service.d 2>/dev/null || true

if [[ $purge_data == true ]]; then
  warn "removing snapshot data under $stargz_root"
  rm -rf "$stargz_root"
else
  [[ ! -d $stargz_root ]] || warn "snapshot data kept under $stargz_root; rerun with --purge-data to delete it"
fi

systemctl daemon-reload
systemctl restart containerd
if systemctl list-unit-files image-cri-shim.service >/dev/null 2>&1 && [[ -f $shim_cfg ]]; then
  systemctl restart image-cri-shim || true
fi
systemctl is-active --quiet containerd || die 'containerd is not active'

if command -v kubectl >/dev/null 2>&1; then
  kubectl delete runtimeclass stargz --ignore-not-found || true
fi

log 'stargz-snapshotter removed; backups remain under /var/backups/sealos-stargz'
