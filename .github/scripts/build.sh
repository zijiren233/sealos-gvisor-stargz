#!/usr/bin/env bash
# Builds one cluster image for one architecture from the current
# application version directory. Run init.sh first so the release
# payloads are present in the context. The images contain no embedded
# container images (runtime binaries and host configs only), so a plain
# docker build of the Kubefile is sufficient; if a future component
# embeds container images, run `sealos registry save` here first.
#
# Usage: build.sh <amd64|arm64>
# Publishes ${IMAGE_NAME}:${VERSION}-<arch> unless SKIP_IMAGE_PUBLISH=true.
set -e

NAME=$(basename "${PWD%/*}")
VERSION=$(basename "$PWD")
ARCH=${1:-amd64}

OWNER=${GITHUB_REPOSITORY_OWNER:-zijiren233}
REPO=${GITHUB_REPOSITORY:-zijiren233/sealos-gvisor-stargz}
IMAGE_REPO=${IMAGE_REPO:-"ghcr.io/${OWNER}"}
IMAGE_NAME=${IMAGE_NAME:-"${IMAGE_REPO}/${NAME}"}
TOKEN=${REGISTRY_TOKEN:-${GITHUB_TOKEN:-}}
SKIP_PUBLISH=${SKIP_IMAGE_PUBLISH:-false}
COMMIT_ID=${BUILD_COMMIT_ID:-${GITHUB_SHA:-none}}

if [[ ! "${ARCH}" =~ ^(amd64|arm64)$ ]]; then
  echo "unsupported architecture: ${ARCH}" >&2
  exit 1
fi

BUILD_FILE=Kubefile
[[ -f Dockerfile ]] && BUILD_FILE=Dockerfile
[[ -f "$BUILD_FILE" ]] || { echo "$BUILD_FILE not found in $(pwd)" >&2; exit 1; }

# Components with init.sh embed release payloads; refuse to build an
# image whose payload was never downloaded (a context without the
# tarball would otherwise build "successfully" but be unusable).
if [[ -f init.sh && ! -f "${NAME}/VERSION" ]]; then
  echo "init.sh must run before build.sh (missing ${NAME}/VERSION in the context)" >&2
  exit 1
fi

export DOCKER_BUILDKIT=${DOCKER_BUILDKIT:-1}
TAG="${IMAGE_NAME}:${VERSION}-${ARCH}"

docker build --platform "linux/${ARCH}" -f "$BUILD_FILE" -t "$TAG" \
  --label org.opencontainers.image.title="${NAME} sealos cluster image" \
  --label org.opencontainers.image.description="sealos patch cluster image for ${NAME} ${VERSION}" \
  --label org.opencontainers.image.source="https://github.com/${REPO}" \
  --label org.opencontainers.image.version="${VERSION}" \
  --label org.opencontainers.image.revision="${COMMIT_ID}" \
  --label org.opencontainers.image.licenses="Apache-2.0" \
  --label org.opencontainers.image.created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  .

if [[ "${SKIP_PUBLISH}" != "true" ]]; then
  [[ -n "${TOKEN}" ]] || { echo "REGISTRY_TOKEN (or GITHUB_TOKEN) is required to publish" >&2; exit 1; }
  printf '%s' "${TOKEN}" | docker login ghcr.io -u "${OWNER}" --password-stdin
  docker push "$TAG"
else
  echo "build only (SKIP_IMAGE_PUBLISH=true): $TAG"
fi
