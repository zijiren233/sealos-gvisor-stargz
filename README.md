# sealos-gvisor-stargz

Sealos cluster images (patch type) that install container runtimes and
snapshotter layers on the nodes of an existing sealos-deployed Kubernetes
cluster:

| Component | Image | Installs | RuntimeClass |
|---|---|---|---|
| gvisor | `ghcr.io/zijiren233/gvisor:<release>` | gVisor `runsc` + `containerd-shim-runsc-v1` | `gvisor` (handler `runsc`) |
| stargz | `ghcr.io/zijiren233/stargz:<version>` | stargz-snapshotter (`containerd-stargz-grpc`, persistent FUSE manager, CRI keychain) | `stargz` (handler `stargz`) |
| gvisor-stargz | `ghcr.io/zijiren233/gvisor-stargz:v1` | combined handler registration only (no binaries); requires both images above | `gvisor-stargz` (handler `runsc-stargz`) |

Each image is self-contained and independent: they can be installed alone
or together, in any order.

## Quick start

```bash
sealos run ghcr.io/zijiren233/gvisor:release-20261026.0
sealos run ghcr.io/zijiren233/stargz:v0.19.1
sealos run ghcr.io/zijiren233/gvisor-stargz:v1   # optional: combined runsc + stargz handler
```

Then schedule pods with the corresponding `runtimeClassName: gvisor`,
`runtimeClassName: stargz` or `runtimeClassName: gvisor-stargz`.

When pulling container images with a non-default handler through the
stargz snapshotter, keep the CRI pull annotation so pulls use the same
snapshotter as pod creation (see `docs` in the containerd CRI config):

```yaml
metadata:
  annotations:
    io.containerd.cri.runtime-handler: stargz
spec:
  runtimeClassName: stargz
```

The same applies to the combined runtime with handler `runsc-stargz`:

```yaml
metadata:
  annotations:
    io.containerd.cri.runtime-handler: runsc-stargz
spec:
  runtimeClassName: gvisor-stargz
```

## Requirements

- sealos v4.4+ / v5 cluster with containerd (`version = 2` config), tested
  against Kubernetes 1.28 + containerd 1.7
- root SSH access to the nodes (sealos runs patch CMDs as root over SSH)
- `tar`, `zstd` (gvisor image) and `systemd` on every node
- no unmanaged runtime state: the installers refuse to run over a
  stargz service they did not install, over existing snapshot data, or
  over a different runsc version (override with the upgrade switches
  below)

## How it works

Both images are sealos **patch** cluster images (`LABEL sealos.io/type="patch"`):

- `sealos run` copies the image payload to every node and executes the
  install script on each node as root, over SSH
- nodes added later with `sealos add --nodes` automatically receive the
  payload and re-run the installer
- re-running `sealos run` of the same image is skipped by sealos; force
  with `sealos run -f` — the installers are idempotent (same version
  means config repair only; a different version is an in-place upgrade:
  the previous binaries and config are backed up under
  `/var/backups/sealos-{gvisor,stargz}/` and containerd is restarted
  only when the effective configuration actually changed)
- all nodes install by default, control-plane nodes included; set the
  per-image `*_SKIP_MASTERS=true` to keep control-plane nodes clean.
  Control-plane nodes run the control plane as static pods, so the
  one-time containerd restart there also restarts that node's static
  pods (kube-apiserver, etcd, ...); on a 3-master cluster etcd keeps
  quorum while sealos applies nodes one at a time. On such nodes the
  stargz CRI keychain also serves static-pod pulls.
- cluster-scoped objects (RuntimeClasses) are applied only on
  control-plane nodes; among those, only nodes holding a kubeconfig
  (`$KUBECONFIG` or `/root/.kube/config`) perform the apply — recent
  sealos keeps `~/.kube/config` on master0 only, so in practice that
  node applies them
  ([labring/sealos#7335](https://github.com/labring/sealos/pull/7335)).
- restarting containerd briefly interrupts CRI on that node; existing
  containers keep running, new pulls/creates retry
- RuntimeClasses are applied with `kubectl apply --server-side` (unique
  field manager per image), so fields this image does not own — e.g. a
  `scheduling.nodeSelector` an existing RuntimeClass carries — are
  preserved instead of stripped

### Production layout parity (stargz)

The stargz image installs **the same layout the manual production
deploy uses**: service `stargz-snapshotter.service`, config-carried
`root`/`address`, data root `/var/lib/containerd-stargz-grpc`, socket
`/run/containerd-stargz-grpc/containerd-stargz-grpc.sock`. Existing
production nodes therefore upgrade in place — a plain version bump, no
service rename and no data relocation:

- `root`, `address` and the `[[resolver.host.*.mirrors]]` entries found
  in an existing config are inherited on every run, so already-pulled
  snapshot data keeps working; the data root is never moved
- a static `/etc/containerd-stargz-grpc/docker` credential dir is kept
  and passed to the snapshotter via `DOCKER_CONFIG`; on such nodes the
  image-cri-shim `cri:` endpoint stays on `containerd.sock` (the
  existing credential flow keeps working) instead of being rewired to
  the CRI keychain
- the unit keeps the production name/description and config-carried
  paths, and gains `Type=notify`, a persistent FUSE manager (mounts
  survive snapshotter restarts from v0.19.1 on) and the CRI keychain
- state on the node always wins over the `STARGZ_ROOT`/`STARGZ_RUN_DIR`
  env defaults — those apply to fresh installs only

> Upgrading a v0.18.2 (pre-FUSE-manager) production node restarts the
> snapshotter once; FUSE mounts created by the old version do not
> survive that restart, so restart stargz-scheduled workloads in the
> same maintenance window.

Everything is embedded in the image at build time (release tarballs with
SHA verification, config files, systemd units). Nodes need no internet
access during install.

## Configuration

Environment variables can be passed with `sealos run -e KEY=VALUE`.

### gvisor

| Variable | Default | Meaning |
|---|---|---|
| `GVISOR_SKIP_MASTERS` | `false` | skip runtime install on control-plane nodes |
| `GVISOR_PLATFORM` | `systrap` | gVisor platform |
| `GVISOR_NETWORK` | `sandbox` | gVisor network mode |
| `GVISOR_ROOT` | `/run/containerd/runsc` | runsc state root |
| `GVISOR_METRICS` | (empty) | metrics exporter endpoint, e.g. `127.0.0.1:2024`; when unset, an upgrade inherits the endpoint from an existing `/etc/containerd/runsc.toml` so a running exporter keeps working; `none` disables |
| `GVISOR_PORT_FORWARD` | `false` | opt-in runsc stream port forwarding (requires a `containerd-gvisor-pf` build): forwarded connections bridge into the gVisor Sentry netstack, so applications listening on the sandbox loopback become reachable. Stock containerd ignores the extra handler fields, so enabling is safe cluster-wide |
| `GVISOR_PORT_FORWARD_BINARY` | `/usr/local/bin/runsc` | helper binary passed to containerd; must be an absolute path |
| `GVISOR_PORT_FORWARD_ROOT` | `$GVISOR_ROOT/k8s.io` | runsc runtime root for CRI sandbox lookup; must be an absolute path |

The combined `gvisor-stargz` image mirrors the `runsc` handler's
port-forward setting onto `runsc-stargz` automatically — the gvisor
image is the single control point for the feature.

The generated `/etc/containerd/runsc.toml` also enables
`systemd-cgroup`, `oci-seccomp`, `directfs`, `overlay2=root:self`,
`file-access=exclusive` and `file-access-mounts=shared`.

### stargz

| Variable | Default | Meaning |
|---|---|---|
| `STARGZ_SKIP_MASTERS` | `false` | skip snapshotter install on control-plane nodes |
| `STARGZ_ROOT` | `/var/lib/containerd-stargz-grpc` | snapshot data root (fresh installs only; existing nodes keep the root recorded in their config) |
| `STARGZ_RUN_DIR` | `/run/containerd-stargz-grpc` | socket/runtime dir |
| `STARGZ_REWIRE_CRI_SHIM` | `true` | point sealos image-cri-shim's `cri:` endpoint at the stargz CRI keychain so pull credentials work; never applied while a static credential dir (`/etc/containerd-stargz-grpc/docker`) exists |
| `STARGZ_INSECURE_REGISTRY` | `sealos.hub:5000` | comma-separated plain-HTTP registries the snapshotter may fetch from (the built-in sealos registry); empty to disable |

The snapshotter runs with `no_background_fetch=true`,
`metadata_store="db"`, a persistent FUSE manager (survives snapshotter
restarts), the CRI keychain (which also inherits containerd's
`config_path`/certs.d registry configuration), and
`allow_invalid_mounts_on_restart=false`. Layer fetching for lazy-pull
images is done by the snapshotter itself, so the built-in sealos
registry must be listed as insecure for eStargz pulls from it to work.

### gvisor-stargz

| Variable | Default | Meaning |
|---|---|---|
| `GVISOR_STARGZ_SKIP_MASTERS` | `false` | skip handler registration on control-plane nodes |

The combined image registers the `runsc-stargz` handler (runtime
`io.containerd.runsc.v1`, snapshotter `stargz`) and applies the
`gvisor-stargz` RuntimeClass. It refuses to run unless the gvisor image
(runsc + runsc.toml) and the stargz image (proxy_plugins.stargz) are
already installed, and re-runs only repair the handler configuration.

## Uninstall

```bash
# on the node (payload dir lives under the sealos data root):
bash <sealos-data-root>/<cluster>/rootfs/gvisor/scripts/uninstall.sh
bash <sealos-data-root>/<cluster>/rootfs/stargz/scripts/uninstall.sh --purge-data
```

gvisor uninstall refuses while RUNNING sandboxes exist. stargz
uninstall keeps snapshot data unless `--purge-data` is given; stop
workloads whose images were pulled through stargz first.

## Known limitations

- **kube-proxy-free CNI (e.g. Cilium in kube-proxy replacement mode)**:
  gVisor sandbox sockets bypass in-pod socket load balancing; set
  `socketLB.hostNamespaceOnly=true` (cluster-level Helm change, apply it
  yourself — these images intentionally never modify the CNI).
- **stargz snapshot metadata**: if the stargz data root is ever wiped
  while containerd metadata still references its snapshots, pod creation
  fails with missing-parent errors; clean the matching snapshot records
  before reinstalling.
- The install flow was validated on a sealos cluster with Kubernetes
  1.28 / containerd 1.7 against gVisor release-20261005.0 and
  stargz-snapshotter v0.18.2 (2026-10). Published tags track newer
  upstream releases; smoke-test a new combination before production use.

## Development

Layout follows the sealos cluster-image conventions
(`applications/<name>/<version>`):

```text
applications/
├── gvisor/release-20261026.0/
│   ├── Kubefile              # FROM scratch, sealos.io/type=patch
│   ├── init.sh               # build-time: download + checksum release payload
│   └── gvisor/
│       ├── scripts/install.sh    # idempotent node installer
│       ├── scripts/uninstall.sh
│       └── manifests/runtimeclass.yaml
└── stargz/v0.19.1/
    ├── Kubefile
    ├── init.sh
    └── stargz/{scripts,manifests}/...
```

`gvisor-stargz/v1/` follows the same layout without `init.sh` — it
embeds no release payloads.

Build locally:

```bash
cd applications/gvisor/release-20261026.0
bash init.sh amd64
docker build -f Kubefile -t ghcr.io/zijiren233/gvisor:release-20261026.0-amd64 .
# or: sealos build -t ghcr.io/zijiren233/gvisor:release-20261026.0 .
```

Add a new version: copy an existing version directory, rename it to the
new version — `init.sh` derives everything from the directory name. A
version directory may carry `skip_amd64` / `skip_arm64` marker files to
exclude an architecture.

CI (GitHub Actions):

- **Build Cluster Images** — on push to `main` (paths `applications/**`)
  or manual dispatch: downloads payloads, builds per-arch images, pushes
  `:<version>-<arch>` to ghcr.io, merges the multi-arch `:<version>`
  manifest. Dispatch inputs can restrict to one component and disable
  publishing.
- **PR Cluster Image Validation** — `bash -n` on all scripts, then
  builds every affected image without publishing and verifies the patch
  label and install CMD.

## License

Apache-2.0. gVisor and stargz-snapshotter artifacts keep their own
licenses (Apache-2.0) and are downloaded from their official GitHub
releases with checksum verification.
