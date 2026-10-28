#!/usr/bin/env bash
# Installs the gVisor runsc runtime on a sealos node and registers the
# `gvisor` RuntimeClass. Runs as the CMD of a patch-type cluster image:
# sealos executes it on every node via SSH, and re-runs it automatically
# on nodes added later with `sealos add --nodes`.
#
# The script is idempotent: re-running against the same release only
# repairs configuration, and containerd is restarted only when the
# effective configuration actually changed.
set -euo pipefail
umask 022

log() { printf '[gvisor] %s\n' "$*"; }
warn() { printf '[gvisor] WARN: %s\n' "$*" >&2; }
die() { printf '[gvisor] ERROR: %s\n' "$*" >&2; exit 1; }

payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cfg=/etc/containerd/config.toml
runsc_toml=/etc/containerd/runsc.toml
backup_root=/var/backups/sealos-gvisor
bin_dir=/usr/local/bin

[[ $(id -u) -eq 0 ]] || die 'must run as root'

for cmd in tar zstd sha512sum systemctl containerd awk sed grep install; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

case $(uname -m) in
  x86_64) artifact=gvisor-x86_64.tar.zstd ;;
  aarch64) artifact=gvisor-aarch64.tar.zstd ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

tarball=$payload_dir/$artifact
sums=$payload_dir/SHA512SUMS
version_file=$payload_dir/VERSION
[[ -f $tarball ]] || die "$tarball not in image; cluster image architecture does not match this node"
[[ -f $sums ]] || die 'SHA512SUMS not in image'
[[ -f $version_file ]] || die 'VERSION not in image; image was built incorrectly'
expected_version=$(cat "$version_file")

apply_runtimeclass() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl apply -f "$payload_dir/manifests/runtimeclass.yaml"
  else
    warn 'kubectl not found; apply gvisor/manifests/runtimeclass.yaml manually'
  fi
}

is_control_plane() {
  [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
}

# Control-plane policy: by default keep the runtime off control-plane
# nodes and only maintain the RuntimeClass object there. Single-node
# clusters must set GVISOR_SKIP_MASTERS=false.
if is_control_plane && [[ ${GVISOR_SKIP_MASTERS:-true} == true ]]; then
  log 'control-plane node: skipping runtime install, applying RuntimeClass only'
  apply_runtimeclass
  exit 0
fi

log "verifying package integrity for ${expected_version}"
(cd "$payload_dir" && grep " ${artifact}\$" SHA512SUMS | sha512sum -c - >/dev/null) || die 'SHA512 checksum mismatch'

[[ -f $cfg ]] || die "missing $cfg"
grep -Eq '^version[[:space:]]*=[[:space:]]*2([[:space:]]*#.*)?$' "$cfg" || die 'containerd config must use version = 2'
! grep -Eq '^[[:space:]]*imports[[:space:]]*=' "$cfg" || die 'containerd config uses imports; merge imported files first'

installed_release() {
  local out
  out=$("$bin_dir/runsc" --version 2>/dev/null | head -n1) || return 1
  grep -oE 'release-[0-9]{8}\.[0-9]+' <<<"$out" || true
}

config_changed=0
fresh_install=1

if [[ -x $bin_dir/runsc ]]; then
  current=$(installed_release) || current=''
  if [[ -n $current && $current == "$expected_version" ]]; then
    log "gVisor ${expected_version} already installed; refreshing configuration"
    fresh_install=0
  else
    [[ ${GVISOR_UPGRADE:-false} == true ]] || \
      die "runsc '${current:-unknown}' is installed but this image ships ${expected_version}; set GVISOR_UPGRADE=true to replace it"
    log "upgrading runsc ${current:-unknown} -> ${expected_version}"
    backup_dir=$backup_root/pre-upgrade-$(date +%Y%m%d%H%M%S)
    install -d -m 700 "$backup_dir"
    cp -a "$bin_dir/runsc" "$backup_dir/" 2>/dev/null || true
    cp -a "$runsc_toml" "$backup_dir/" 2>/dev/null || true
    cp -a "$cfg" "$backup_dir/containerd-config.toml"
  fi
fi

render_runsc_toml() {
  local platform=${GVISOR_PLATFORM:-systrap}
  local network=${GVISOR_NETWORK:-sandbox}
  local root_dir=${GVISOR_ROOT:-/run/containerd/runsc}
  local metrics=${GVISOR_METRICS:-}
  cat <<EOF
binary_name = "$bin_dir/runsc"
root = "$root_dir"
[runsc_config]
  platform = "$platform"
  systemd-cgroup = "true"
  network = "$network"
  oci-seccomp = "true"
  directfs = "true"
  overlay2 = "root:self"
  file-access = "exclusive"
  file-access-mounts = "shared"
EOF
  [[ -z $metrics ]] || printf '  metric-server = "%s"\n' "$metrics"
}

render_containerd_config() {
  # Replaces this image's runsc handler blocks in place, keeping their
  # position in the file; appends them at the end only when absent.
  # This keeps repeated runs byte-stable (regardless of the order other
  # runtime images re-run) so containerd is not restarted when nothing
  # actually changed.
  local blocks
  blocks=$(mktemp)
  cat >"$blocks" <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
  snapshotter = "overlayfs"
  privileged_without_host_devices = true
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
EOF
  awk '
    NR==FNR { block[++n] = $0; next }
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc\][[:space:]]*$/ {
      if (!done) { for (i = 1; i <= n; i++) print block[i]; done = 1 }
      skip = 1; pending = 0; next
    }
    /^[[:space:]]*\[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.runsc\.options\][[:space:]]*$/ { skip = 1; next }
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

log 'writing runsc and containerd configuration'
render_runsc_toml | write_if_changed "$runsc_toml" || true
render_tmp=$(mktemp)
if ! render_containerd_config >"$render_tmp"; then
  rm -f "$render_tmp"
  die 'failed to render containerd configuration'
fi
write_if_changed "$cfg" <"$render_tmp" || true
rm -f "$render_tmp"

if [[ $fresh_install -eq 1 ]]; then
  log "installing binaries from ${artifact}"
  tar --zstd -xf "$tarball" -C "$bin_dir"
  [[ -x $bin_dir/runsc ]] || die 'runsc binary missing from package'
  config_changed=1
fi

containerd --config "$cfg" config dump >/dev/null || die 'containerd rejected the merged configuration'

if [[ $config_changed -eq 1 ]]; then
  log 'restarting containerd (brief CRI interruption on this node)'
  systemctl restart containerd
else
  log 'configuration unchanged; containerd restart not needed'
fi

# Optional metrics exporter; enabled only when GVISOR_METRICS is set.
if [[ -n ${GVISOR_METRICS:-} ]]; then
  root_dir=${GVISOR_ROOT:-/run/containerd/runsc}
  cat >/etc/systemd/system/gvisor-metrics.service <<EOF
[Unit]
Description=gVisor sandbox Prometheus exporter
After=containerd.service
[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -m 0700 ${root_dir}/k8s.io
ExecStart=${bin_dir}/runsc --root=${root_dir}/k8s.io --metric-server=${GVISOR_METRICS} metric-server
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now gvisor-metrics
fi

systemctl is-active --quiet containerd || die 'containerd is not active'
runsc --version | head -n1
if command -v crictl >/dev/null 2>&1; then
  crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null || die 'CRI health check failed'
else
  warn 'crictl not found; skipping CRI health check'
fi

if is_control_plane; then
  apply_runtimeclass
fi
log "gVisor ${expected_version} installed (handler: runsc, RuntimeClass: gvisor)"
