#!/usr/bin/env bash
# Installs stargz-snapshotter (containerd-stargz-grpc with persistent
# FUSE manager and CRI keychain) on a sealos node and registers the
# `stargz` RuntimeClass. Runs as the CMD of a patch-type cluster image:
# sealos executes it on every node via SSH, and re-runs it automatically
# on nodes added later with `sealos add --nodes`.
#
# The script is idempotent: re-running against the same release only
# repairs configuration, and services are restarted only when the
# effective configuration actually changed.
set -euo pipefail
umask 022

log() { printf '[stargz] %s\n' "$*"; }
warn() { printf '[stargz] WARN: %s\n' "$*" >&2; }
die() { printf '[stargz] ERROR: %s\n' "$*" >&2; exit 1; }

payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cfg=/etc/containerd/config.toml
shim_cfg=/etc/image-cri-shim.yaml
backup_root=/var/backups/sealos-stargz
bin_dir=/usr/local/bin

stargz_root=${STARGZ_ROOT:-/var/lib/containerd/stargz-snapshotter}
run_dir=${STARGZ_RUN_DIR:-/run/containerd-stargz-grpc}
stargz_service=containerd-stargz-grpc.service
config_dir=/etc/containerd-stargz-grpc
cri_sock=$run_dir/cri.sock
snapshot_sock=$run_dir/containerd-stargz-grpc.sock

[[ $(id -u) -eq 0 ]] || die 'must run as root'

for cmd in tar sha256sum systemctl containerd awk sed grep install; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

case $(uname -m) in
  x86_64) arch=amd64 ;;
  aarch64) arch=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

version_file=$payload_dir/VERSION
[[ -f $version_file ]] || die 'VERSION not in image; image was built incorrectly'
expected_version=$(cat "$version_file")
artifact="stargz-snapshotter-${expected_version}-linux-${arch}.tar.gz"
tarball=$payload_dir/$artifact
[[ -f $tarball ]] || die "$tarball not in image; cluster image architecture does not match this node"

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
  kubectl --kubeconfig "$kubeconfig" apply -f "$payload_dir/manifests/runtimeclass.yaml"
}

is_control_plane() {
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
}

if is_control_plane && [[ ${STARGZ_SKIP_MASTERS:-true} == true ]]; then
  log 'control-plane node: skipping snapshotter install, applying RuntimeClass only'
  apply_runtimeclass
  exit 0
fi

log "verifying package integrity for ${expected_version}"
(cd "$payload_dir" && sha256sum -c "${artifact}.sha256sum" >/dev/null) || die 'SHA256 checksum mismatch'

[[ -f $cfg ]] || die "missing $cfg"
grep -Eq '^version[[:space:]]*=[[:space:]]*2([[:space:]]*#.*)?$' "$cfg" || die 'containerd config must use version = 2'
! grep -Eq '^[[:space:]]*imports[[:space:]]*=' "$cfg" || die 'containerd config uses imports; merge imported files first'

# A stargz installation this image does not manage: refuse rather than
# fight an unknown service layout for the snapshot data root.
if [[ -f /etc/systemd/system/stargz-snapshotter.service ]]; then
  die 'found an unmanaged stargz-snapshotter.service; this image only manages its own containerd-stargz-grpc.service layout'
fi

config_changed=0
fresh_install=1

installed_release() {
  local out
  out=$("$bin_dir/containerd-stargz-grpc" --version 2>/dev/null | head -n1) || return 1
  grep -oE "v[0-9]+\.[0-9]+\.[0-9]+" <<<"$out" || true
}

if [[ -x $bin_dir/containerd-stargz-grpc ]]; then
  current=$(installed_release) || current=''
  if [[ -n $current && $current == "$expected_version" ]]; then
    log "stargz-snapshotter ${expected_version} already installed; refreshing configuration"
    fresh_install=0
  else
    log "upgrading stargz-snapshotter ${current:-unknown} -> ${expected_version} (existing snapshot data is preserved)"
  fi
fi

# Orphaned snapshot data with no managed binary is ambiguous (e.g. a
# rebuilt node); upgrading an installation that owns the data is fine.
if [[ ! -x $bin_dir/containerd-stargz-grpc && -d $stargz_root ]] && find "$stargz_root" -mindepth 1 -print -quit | grep -q .; then
  die "existing data under $stargz_root but no managed snapshotter binary; inspect and move the data before installing"
fi

write_if_changed() {
  local target=$1 tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ ! -f $target ]] || ! cmp -s "$tmp" "$target"; then
    if [[ -f $target ]]; then
      install -d -m 700 "$backup_root/initial" 2>/dev/null || true
      cp -a "$target" "$backup_root/initial/$(basename "$target").orig" 2>/dev/null || true
    fi
    install -D -m 644 "$tmp" "$target"
    rm -f "$tmp"
    config_changed=1
    return 0
  fi
  rm -f "$tmp"
  return 1
}

log 'writing snapshotter configuration and systemd units'
render_stargz_toml() {
  cat <<EOF
no_background_fetch = true
noprefetch = false
allow_no_verification = false
disable_verification = false
metrics_address = "127.0.0.1:2023"
metadata_store = "db"
[fuse_manager]
  enable = true
  address = "$run_dir/fuse-manager.sock"
  path = "$bin_dir/stargz-fuse-manager"
[cri_keychain]
  enable_keychain = true
  image_service_path = "/run/containerd/containerd.sock"
  listen_path = "$cri_sock"
[snapshotter]
  allow_invalid_mounts_on_restart = false
[resolver]
  request_timeout_sec = 30
EOF
  # Plain-HTTP registries (sealos clusters ship a built-in one). The
  # snapshotter resolves and fetches layers on its own, so it needs this
  # even though containerd itself is already configured for the registry.
  local registries=${STARGZ_INSECURE_REGISTRY-sealos.hub:5000}
  local registry
  for registry in ${registries//,/ }; do
    [[ -n $registry ]] || continue
    cat <<EOF
[[resolver.host."${registry}".mirrors]]
  host = "${registry}"
  insecure = true
EOF
  done
}

render_service() {
  cat <<EOF
[Unit]
Description=Stargz snapshotter with persistent FUSE manager
After=network.target
Before=containerd.service
RequiresMountsFor=$stargz_root
[Service]
Type=notify
ExecStart=$bin_dir/containerd-stargz-grpc --address=$snapshot_sock --config=$config_dir/config.toml --root=$stargz_root --log-level=info
Restart=always
RestartSec=5
KillMode=process
LimitNOFILE=1048576
TasksMax=infinity
Delegate=yes
[Install]
WantedBy=multi-user.target
EOF
}

render_containerd_dropin() {
  cat <<EOF
[Unit]
Wants=$stargz_service
After=$stargz_service
[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
}

render_shim_dropin() {
  cat <<EOF
[Unit]
Wants=containerd.service $stargz_service
After=containerd.service $stargz_service
EOF
}

render_logrotate() {
  cat <<EOF
$stargz_root/stargz-fuse-manager.log {
    daily
    rotate 7
    maxsize 20M
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
EOF
}

# The two merge helpers below replace one block group (main table plus
# its sub table) in place, keeping its position in the stream; they
# append the group at the end only when absent. This keeps repeated runs
# byte-stable regardless of the order other runtime images re-run.
# Header regexes are inline (not -v variables) so backslash escapes
# survive awk's -v escape processing.
replace_handler_group() {
  local blocks=$1
  awk '
    NR==FNR { block[++n] = $0; next }
    /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.stargz\][[:space:]]*$/ {
      if (!done) { for (i = 1; i <= n; i++) print block[i]; done = 1 }
      skip = 1; pending = 0; next
    }
    /^\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.stargz\.options\][[:space:]]*$/ { skip = 1; next }
    /^[[:space:]]*\[/ {
      if (skip && pending) print ""
      skip = 0
      pending = 0
    }
    skip && /^[[:space:]]*$/ { pending = 1; next }
    skip { next }
    { print }
    END { if (!done) { print ""; for (i = 1; i <= n; i++) print block[i] } }
  ' "$blocks" -
}

replace_proxy_group() {
  local blocks=$1
  awk '
    NR==FNR { block[++n] = $0; next }
    /^\[proxy_plugins\.stargz\][[:space:]]*$/ {
      if (!done) { for (i = 1; i <= n; i++) print block[i]; done = 1 }
      skip = 1; pending = 0; next
    }
    /^\[proxy_plugins\.stargz\.exports\][[:space:]]*$/ { skip = 1; next }
    /^[[:space:]]*\[/ {
      if (skip && pending) print ""
      skip = 0
      pending = 0
    }
    skip && /^[[:space:]]*$/ { pending = 1; next }
    skip { next }
    { print }
    END { if (!done) { print ""; for (i = 1; i <= n; i++) print block[i] } }
  ' "$blocks" -
}

# containerd config merge: force disable_snapshot_annotations = false
# inside the CRI containerd table (pull annotations must survive for
# handler-scoped snapshotters), then register/refresh this image's
# handler and proxy plugin block groups in place.
render_containerd_config() {
  local handler_blocks proxy_blocks
  handler_blocks=$(mktemp)
  proxy_blocks=$(mktemp)
  cat >"$handler_blocks" <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.stargz]
  runtime_type = "io.containerd.runc.v2"
  snapshotter = "stargz"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.stargz.options]
  SystemdCgroup = true
EOF
  cat >"$proxy_blocks" <<EOF
[proxy_plugins.stargz]
  type = "snapshot"
  address = "$snapshot_sock"
[proxy_plugins.stargz.exports]
  root = "$stargz_root"
EOF
  awk '
    BEGIN { in_cri=0; found=0 }
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\][[:space:]]*$/ { in_cri=1; found=1; print; next }
    /^[[:space:]]*\[/ { if (in_cri && !seen) { print "  disable_snapshot_annotations = false"; seen=1 }; in_cri=0 }
    in_cri && /^[[:space:]]*disable_snapshot_annotations[[:space:]]*=/ { print "  disable_snapshot_annotations = false"; seen=1; next }
    { print }
    END {
      if (in_cri && !seen) print "  disable_snapshot_annotations = false"
      if (!found) exit 2
    }
  ' "$cfg" \
    | replace_handler_group "$handler_blocks" \
    | replace_proxy_group "$proxy_blocks"
  rm -f "$handler_blocks" "$proxy_blocks"
}

render_stargz_toml | write_if_changed "$config_dir/config.toml" || true
render_service | write_if_changed "/etc/systemd/system/$stargz_service" || true
render_containerd_dropin | write_if_changed "/etc/systemd/system/containerd.service.d/20-stargz.conf" || true
render_shim_dropin | write_if_changed "/etc/systemd/system/image-cri-shim.service.d/20-stargz.conf" || true
render_logrotate | write_if_changed /etc/logrotate.d/stargz-snapshotter || true
render_tmp=$(mktemp)
if ! render_containerd_config >"$render_tmp"; then
  rm -f "$render_tmp"
  die 'CRI containerd table not found in containerd config'
fi
write_if_changed "$cfg" <"$render_tmp" || true
rm -f "$render_tmp"

rewired_shim=0
if [[ ${STARGZ_REWIRE_CRI_SHIM:-true} == true ]]; then
  if [[ -f $shim_cfg ]] && grep -Eq '^cri:[[:space:]]*(/run|/var/run)/containerd/containerd\.sock[[:space:]]*$' "$shim_cfg"; then
    sed -i -E "s#^cri:[[:space:]]*(/run|/var/run)/containerd/containerd\.sock[[:space:]]*\$#cri: $cri_sock#" "$shim_cfg"
    grep -Eq "^cri:[[:space:]]*$cri_sock[[:space:]]*\$" "$shim_cfg" || die 'failed to update image-cri-shim cri endpoint'
    log "image-cri-shim cri endpoint now $cri_sock (pull credentials flow through the stargz CRI keychain)"
    rewired_shim=1
  elif [[ -f $shim_cfg ]]; then
    warn 'image-cri-shim cri endpoint is not containerd.sock; leaving it untouched'
  else
    warn 'no /etc/image-cri-shim.yaml; skipping image-cri-shim rewiring'
  fi
fi

if [[ $fresh_install -eq 1 ]]; then
  log "installing binaries from ${artifact}"
  tar -xzf "$tarball" -C "$bin_dir" containerd-stargz-grpc stargz-fuse-manager ctr-remote
  [[ -x $bin_dir/containerd-stargz-grpc ]] || die 'containerd-stargz-grpc missing from package'
  config_changed=1
fi

containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the merged configuration'

systemctl daemon-reload
systemctl enable --now "$stargz_service" >/dev/null

if [[ $config_changed -eq 1 ]] || ! systemctl is-active --quiet "$stargz_service"; then
  log 'starting snapshotter and restarting containerd (brief CRI interruption on this node)'
  systemctl restart "$stargz_service"
  for _ in $(seq 1 30); do [[ -S $cri_sock ]] && break; sleep 1; done
  [[ -S $cri_sock ]] || die "stargz CRI keychain socket $cri_sock not ready"
  systemctl restart containerd
  if [[ $rewired_shim -eq 1 ]]; then
    systemctl restart image-cri-shim
  fi
else
  log 'configuration unchanged; containerd restart not needed'
fi

systemctl is-active --quiet containerd || die 'containerd is not active'
systemctl is-active --quiet "$stargz_service" || die "$stargz_service is not active"
# capture instead of piping: grep -q closes early and kills ctr with
# SIGPIPE under pipefail, producing a false warning
plugins_out=$(ctr plugins ls 2>/dev/null || true)
[[ $plugins_out == *stargz* ]] || warn 'stargz plugin not visible in ctr plugins ls'
if command -v crictl >/dev/null 2>&1; then
  crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null || die 'CRI health check failed'
else
  warn 'crictl not found; skipping CRI health check'
fi
"$bin_dir/containerd-stargz-grpc" --version | head -n1

apply_runtimeclass
log "stargz-snapshotter ${expected_version} installed (handler: stargz, RuntimeClass: stargz)"
