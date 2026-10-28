#!/usr/bin/env bash
# Merges the per-architecture images of one component version into a
# multi-arch manifest tag. Respects skip_amd64 / skip_arm64 markers.
#
# Usage: manifest.sh <project> <version> [token]
set -e

name=${1:?project name required}
version=${2:?version required}
token=${3:-}

OWNER=${GITHUB_REPOSITORY_OWNER:-zijiren233}
IMAGE_NAME=${IMAGE_NAME:-"ghcr.io/${OWNER}/${name}"}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
dir="${ROOT}/applications/${name}/${version}"

if [[ -f "$dir/skip_amd64" && -f "$dir/skip_arm64" ]]; then
  echo "both skip_amd64 and skip_arm64 found in $dir; only one is allowed" >&2
  exit 1
fi

if [[ -n "${token}" ]]; then
  printf '%s' "${token}" | docker login ghcr.io -u "${OWNER}" --password-stdin
fi

sources=()
for arch in amd64 arm64; do
  [[ -f "$dir/skip_${arch}" ]] && continue
  sources+=("${IMAGE_NAME}:${version}-${arch}")
done
[[ ${#sources[@]} -gt 0 ]] || { echo "no per-arch images to merge for ${name}:${version}" >&2; exit 1; }

docker buildx imagetools create -t "${IMAGE_NAME}:${version}" "${sources[@]}"
docker buildx imagetools inspect "${IMAGE_NAME}:${version}"
echo "${IMAGE_NAME}:${version} manifest pushed"
