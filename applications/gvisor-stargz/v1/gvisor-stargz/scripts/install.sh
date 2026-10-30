#!/usr/bin/env bash
# Registers the combined gVisor + stargz runtime (containerd handler
# `runsc-stargz`, snapshotter stargz) and the `gvisor-stargz`
# RuntimeClass. This image carries configuration only: the gvisor image
# (runsc, shim, runsc.toml) and the stargz image (snapshotter,
# proxy_plugins.stargz) must be installed first.
set -euo pipefail
umask 022

log() { printf '[gvisor-stargz] %s\n' "$*"; }
warn() { printf '[gvisor-stargz] WARN: %s\n' "$*" >&2; }
die() { printf '[gvisor-stargz] ERROR: %s\n' "$*" >&2; exit 1; }

payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cfg=/etc/containerd/config.toml
runsc_toml=/etc/containerd/runsc.toml
backup_root=/var/backups/sealos-gvisor-stargz

[[ $(id -u) -eq 0 ]] || die 'must run as root'

for cmd in systemctl containerd awk grep install; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

# Cluster-scoped objects are applied only on the node holding a
# kubeconfig: recent sealos keeps /root/.kube/config on master0 only
# (labring/sealos#7335), so its presence is the natural signal.
kubeconfig_path() {
  if [[ -n ${KUBECONFIG:-} && -f ${KUBECONFIG} ]]; then
    printf '%s
' "$KUBECONFIG"
    return 0
  fi
  [[ -f /root/.kube/config ]] && { printf '%s
' /root/.kube/config; return 0; }
  return 1
}

apply_runtimeclass() {
  local kubeconfig
  if ! kubeconfig=$(kubeconfig_path); then
    log 'no kubeconfig on this node; RuntimeClass is applied on the node holding ~/.kube/config only'
    return 0
  fi
  command -v kubectl >/dev/null 2>&1 || { warn 'kubectl not found; apply the RuntimeClass manifest manually'; return 0; }
  # Server-side apply keeps fields this image does not own (e.g. a
  # scheduling.nodeSelector an existing RuntimeClass carries); plain
  # client-side apply would strip them. A failing apply (e.g. a second
  # node holding a kubeconfig with a rotated CA) must not fail the node
  # install: the manifest is cluster-scoped, so any one healthy node
  # applying it is enough.
  if ! kubectl --kubeconfig "$kubeconfig" apply --server-side --field-manager=sealos-gvisor-stargz-image -f "$payload_dir/manifests/runtimeclass.yaml" >/dev/null 2>&1; then
    if ! kubectl --kubeconfig "$kubeconfig" apply -f "$payload_dir/manifests/runtimeclass.yaml" >/dev/null 2>&1; then
      warn "RuntimeClass apply via $kubeconfig failed; another node holding a working kubeconfig applies it, or apply the manifest manually"
    fi
  fi
}

is_control_plane() {
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
}

# Register the handler on every node by default; set
# GVISOR_STARGZ_SKIP_MASTERS=true to leave control-plane nodes untouched.
if is_control_plane && [[ ${GVISOR_STARGZ_SKIP_MASTERS:-false} == true ]]; then
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
  # Mirror the runsc handler's stream port-forward setting (set by the
  # gvisor image) onto this handler so both stay in sync; the gvisor
  # image is the single control point for the feature.
  local pf_binary pf_root
  read -r pf_binary pf_root < <(awk '
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc\][[:space:]]*$/ { inrun = 1; next }
    /^[[:space:]]*\[/ { inrun = 0 }
    inrun && /^[[:space:]]*runsc_port_forward_binary[[:space:]]*=/ { gsub(/[",[:space:]]/, "", $3); b = $3 }
    inrun && /^[[:space:]]*runsc_port_forward_root[[:space:]]*=/ { gsub(/[",[:space:]]/, "", $3); r = $3 }
    END { printf "%s %s\n", b, r }
  ' "$cfg")
  blocks=$(mktemp)
  cat >"$blocks" <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc-stargz]
  runtime_type = "io.containerd.runsc.v1"
  snapshotter = "stargz"
  privileged_without_host_devices = true
EOF
  if [[ -n $pf_binary && -n $pf_root ]]; then
    printf '  runsc_port_forward_binary = "%s"\n  runsc_port_forward_root = "%s"\n' \
      "$pf_binary" "$pf_root" >>"$blocks"
  fi
  cat >>"$blocks" <<'EOF'
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

apply_runtimeclass
log 'combined runtime registered (handler: runsc-stargz, RuntimeClass: gvisor-stargz)'
