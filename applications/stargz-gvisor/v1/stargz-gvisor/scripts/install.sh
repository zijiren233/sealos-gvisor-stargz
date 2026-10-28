#!/usr/bin/env bash
# Registers the combined gVisor + stargz runtime (containerd handler
# `runsc-stargz`, snapshotter stargz) and the `gvisor-stargz`
# RuntimeClass. This image carries configuration only: the gvisor image
# (runsc, shim, runsc.toml) and the stargz image (snapshotter,
# proxy_plugins.stargz) must be installed first.
set -euo pipefail
umask 022

log() { printf '[stargz-gvisor] %s\n' "$*"; }
warn() { printf '[stargz-gvisor] WARN: %s\n' "$*" >&2; }
die() { printf '[stargz-gvisor] ERROR: %s\n' "$*" >&2; exit 1; }

payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cfg=/etc/containerd/config.toml
runsc_toml=/etc/containerd/runsc.toml
backup_root=/var/backups/sealos-stargz-gvisor

[[ $(id -u) -eq 0 ]] || die 'must run as root'

for cmd in systemctl containerd awk grep install; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

apply_runtimeclass() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl apply -f "$payload_dir/manifests/runtimeclass.yaml"
  else
    warn 'kubectl not found; apply stargz-gvisor/manifests/runtimeclass.yaml manually'
  fi
}

is_control_plane() {
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
}

if is_control_plane && [[ ${STARGZ_GVISOR_SKIP_MASTERS:-true} == true ]]; then
  log 'control-plane node: skipping handler registration, applying RuntimeClass only'
  apply_runtimeclass
  exit 0
fi

[[ -f $cfg ]] || die "missing $cfg"
grep -Eq '^version[[:space:]]*=[[:space:]]*2([[:space:]]*#.*)?$' "$cfg" || die 'containerd config must use version = 2'
! grep -Eq '^[[:space:]]*imports[[:space:]]*=' "$cfg" || die 'containerd config uses imports; merge imported files first'

[[ -x /usr/local/bin/runsc ]] || die 'runsc not found; install the gvisor cluster image first'
[[ -f $runsc_toml ]] || die "$runsc_toml not found; install the gvisor cluster image first"
grep -Eq '^\[proxy_plugins\.stargz\]' "$cfg" || die 'proxy_plugins.stargz not configured; install the stargz cluster image first'

render_containerd_config() {
  # Replaces this image's runsc-stargz handler blocks in place, keeping
  # their position in the file; appends them at the end only when
  # absent. This keeps repeated runs byte-stable (regardless of the
  # order other runtime images re-run) so containerd is not restarted
  # when nothing actually changed.
  local blocks
  blocks=$(mktemp)
  cat >"$blocks" <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc-stargz]
  runtime_type = "io.containerd.runsc.v1"
  snapshotter = "stargz"
  privileged_without_host_devices = true
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc-stargz.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
EOF
  awk '
    NR==FNR { block[++n] = $0; next }
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc-stargz\][[:space:]]*$/ {
      if (!done) { for (i = 1; i <= n; i++) print block[i]; done = 1 }
      skip = 1; pending = 0; next
    }
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc-stargz\.options\][[:space:]]*$/ { skip = 1; next }
    /^[[:space:]]*\[/ {
      if (skip && pending) print ""
      skip = 0
      pending = 0
    }
    skip && /^[[:space:]]*$/ { pending = 1; next }
    skip { next }
    { print }
    END { if (!done) { print ""; for (i = 1; i <= n; i++) print block[i] } }
  ' "$blocks" "$cfg"
  rm -f "$blocks"
}

config_changed=0
write_if_changed() {
  local target=$1 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ ! -f $target ]] || ! cmp -s "$tmp" "$target"; then
    if [[ -f $target ]]; then
      install -d -m 700 "$backup_root/initial" 2>/dev/null || true
      cp -a "$target" "$backup_root/initial/$(basename "$target").orig" 2>/dev/null || true
    fi
    install -m 644 "$tmp" "$target"
    rm -f "$tmp"
    config_changed=1
    return 0
  fi
  rm -f "$tmp"
  return 1
}

log 'registering runsc-stargz runtime handler'
render_tmp=$(mktemp)
if ! render_containerd_config >"$render_tmp"; then
  rm -f "$render_tmp"
  die 'failed to render containerd configuration'
fi
write_if_changed "$cfg" <"$render_tmp" || true
rm -f "$render_tmp"

containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the merged configuration'

if [[ $config_changed -eq 1 ]]; then
  log 'restarting containerd (brief CRI interruption on this node)'
  systemctl restart containerd
else
  log 'configuration unchanged; containerd restart not needed'
fi

systemctl is-active --quiet containerd || die 'containerd is not active'
/usr/local/bin/runsc --version | head -n1
if command -v crictl >/dev/null 2>&1; then
  crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null || die 'CRI health check failed'
else
  warn 'crictl not found; skipping CRI health check'
fi

if is_control_plane; then
  apply_runtimeclass
fi
log 'combined runtime registered (handler: runsc-stargz, RuntimeClass: gvisor-stargz)'
