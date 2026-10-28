#!/usr/bin/env bash
# Downloads the pinned gVisor release into the build context so the
# cluster image carries the runtime binaries and no node needs internet
# access at install time.
set -e

cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1
readonly ARCH=${1:-amd64}
readonly NAME=${2:-$(basename "${PWD%/*}")}
readonly VERSION=${3:-$(basename "$PWD")}

readonly GVISOR_BASE="https://github.com/google/gvisor/releases/download"

case "${ARCH}" in
  amd64) artifact="gvisor-x86_64.tar.zstd" ;;
  arm64) artifact="gvisor-aarch64.tar.zstd" ;;
  *)
    echo "unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

mkdir -p "${NAME}"
curl -fL --retry 3 --connect-timeout 15 --max-time 600 \
  "${GVISOR_BASE}/${VERSION}/${artifact}" -o "${NAME}/${artifact}"
curl -fL --retry 3 --connect-timeout 15 --max-time 120 \
  "${GVISOR_BASE}/${VERSION}/SHA512SUMS" -o "${NAME}/SHA512SUMS"

(
  cd "${NAME}"
  grep " ${artifact}\$" SHA512SUMS | sha512sum -c -
)
echo "${VERSION}" >"${NAME}/VERSION"
echo "gVisor ${VERSION} (${ARCH}) downloaded and verified"
