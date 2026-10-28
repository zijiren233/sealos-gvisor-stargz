#!/usr/bin/env bash
# Emits the build matrix for cluster images defined under applications/.
# Layout: applications/<project>/<version>/{Kubefile,init.sh}.
# A version directory may carry skip_amd64 / skip_arm64 marker files to
# exclude an architecture. IMAGE_NAME / SKIP_IMAGE_NAME restrict the
# project set (comma separated).
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}/../.."

image=${IMAGE_NAME:-}
skipProjects=${SKIP_IMAGE_NAME:-}

projects=$(ls -d applications/*/ 2>/dev/null | sed 's#applications/##;s#/##')
if [[ -n "$image" ]]; then
  projects=$image
fi

IFS=',' read -ra SKIP_ARRAY <<<"${skipProjects// /,}"
should_skip() {
  local proj="$1" skip
  for skip in "${SKIP_ARRAY[@]}"; do
    [[ "$proj" == "$skip" ]] && return 0
  done
  return 1
}

matrix='{"include":['
for project in $projects; do
  [[ -d "applications/$project" ]] || continue
  should_skip "$project" && continue
  for version_dir in "applications/$project"/*/; do
    [[ -f "${version_dir}Kubefile" ]] || continue
    version=$(basename "$version_dir")
    dir="applications/$project/$version"
    skip_amd=0
    skip_arm=0
    [[ -f "$dir/skip_amd64" ]] && skip_amd=1
    [[ -f "$dir/skip_arm64" ]] && skip_arm=1
    if [[ $skip_amd -eq 1 && $skip_arm -eq 1 ]]; then
      echo "both skip_amd64 and skip_arm64 found in $dir; only one is allowed" >&2
      exit 1
    fi
    [[ $skip_amd -eq 0 ]] && matrix+="{\"project\":\"$project\",\"version\":\"$version\",\"arch\":\"amd64\"},"
    [[ $skip_arm -eq 0 ]] && matrix+="{\"project\":\"$project\",\"version\":\"$version\",\"arch\":\"arm64\"},"
  done
done
matrix="${matrix%,}]}"
echo "matrix=$matrix"
