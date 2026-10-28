#!/usr/bin/env bash
# Downloads the pinned stargz-snapshotter release into the build context
# so the cluster image carries the binaries and no node needs internet
# access at install time.
set -e

cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1
readonly ARCH=${1:-amd64}
readonly NAME=${2:-$(basename "${PWD%/*}")}
readonly VERSION=${3:-$(basename "$PWD")}

readonly STARGZ_BASE="https://github.com/containerd/stargz-snapshotter/releases/download"

case "${ARCH}" in
  amd64|arm64) : ;;
  *)
    echo "unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

artifact="stargz-snapshotter-${VERSION}-linux-${ARCH}.tar.gz"

mkdir -p "${NAME}"
curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
  "${STARGZ_BASE}/${VERSION}/${artifact}" -o "${NAME}/${artifact}"
curl -fL --retry 3 --connect-timeout 15 --max-time 60 \
  "${STARGZ_BASE}/${VERSION}/${artifact}.sha256sum" -o "${NAME}/${artifact}.sha256sum"

(
  cd "${NAME}"
  sha256sum -c "${artifact}.sha256sum"
)
echo "${VERSION}" >"${NAME}/VERSION"
echo "stargz-snapshotter ${VERSION} (${ARCH}) downloaded and verified"
