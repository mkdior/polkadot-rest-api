#!/usr/bin/env bash

set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
# shellcheck source=release-common.sh
source "${script_dir}/release-common.sh"

validate_release_environment
[[ $(git -C "$repo_root" rev-parse HEAD) == "$PUBLISHER_COMMIT" ]] \
  || die "trusted build scripts do not match the publisher workflow commit"
verify_upstream_approval
# The hostile upstream build does not need even the read-only GitHub token.
unset GH_TOKEN

source_dir="${RUNNER_TEMP}/upstream-source"
pinned_dockerfile="${RUNNER_TEMP}/Dockerfile.pinned"
[[ ! -e "$source_dir" ]] || die "temporary upstream source path unexpectedly exists"
[[ ! -e "$repo_root/dist" ]] || die "dist must be absent at the start of the build"
mkdir -p -- "$source_dir" "$repo_root/dist"
git -C "$source_dir" init --quiet
git -C "$source_dir" remote add upstream "$UPSTREAM_URL"
git -C "$source_dir" fetch --quiet --depth=1 upstream \
  "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
[[ $(git -C "$source_dir" rev-parse "$UPSTREAM_TAG") == "$UPSTREAM_TAG_OBJECT" ]] \
  || die "fetched tag object differs from the approval"
[[ $(git -C "$source_dir" rev-parse "${UPSTREAM_TAG}^{commit}") == "$UPSTREAM_COMMIT" ]] \
  || die "fetched tag commit differs from the approval"
git -C "$source_dir" checkout --quiet --detach "$UPSTREAM_COMMIT"

for source_file in Dockerfile Cargo.toml Cargo.lock; do
  [[ -f "${source_dir}/${source_file}" && ! -L "${source_dir}/${source_file}" ]] \
    || die "upstream ${source_file} is not a regular non-symlink file"
done

workspace_version=$(awk '
  $0 == "[workspace.package]" { in_workspace = 1; next }
  /^\[/ { in_workspace = 0 }
  in_workspace && $1 == "version" {
    value = $3
    gsub(/"/, "", value)
    print value
    exit
  }
' "${source_dir}/Cargo.toml")
[[ "$workspace_version" == "$VERSION" ]] \
  || die "approved version ${VERSION} differs from Cargo.toml version ${workspace_version:-missing}"

builder_source=${BUILDER_BASE%@sha256:*}
runtime_source=${RUNTIME_BASE%@sha256:*}
awk \
  -v builder_source="$builder_source" -v builder_pinned="$BUILDER_BASE" \
  -v runtime_source="$runtime_source" -v runtime_pinned="$RUNTIME_BASE" '
  toupper($1) == "FROM" {
    from_count++
    if ($2 == builder_source) {
      $2 = builder_pinned
      builder_count++
    } else if ($2 == runtime_source) {
      $2 = runtime_pinned
      runtime_count++
    } else {
      bad = 1
    }
  }
  { print }
  END {
    if (bad || from_count != 2 || builder_count != 1 || runtime_count != 1) exit 42
  }
' "${source_dir}/Dockerfile" >"$pinned_dockerfile" \
  || die "upstream Dockerfile base stages do not exactly match the reviewed pinned inputs"

binary=$(binary_name)
checksum=$(checksum_name)
provenance=$(provenance_name)
binary_path="${repo_root}/dist/${binary}"
checksum_path="${repo_root}/dist/${checksum}"
provenance_path="${repo_root}/dist/${provenance}"
image="local/polkadot-rest-api:${UPSTREAM_COMMIT:0:12}"
container_id=''
cleanup() {
  if [[ -n "$container_id" ]]; then
    docker rm -f "$container_id" >/dev/null 2>&1 || true
  fi
  docker image rm "$image" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_date=$(date -u +%FT%TZ)
docker build \
  --file "$pinned_dockerfile" \
  --tag "$image" \
  --build-arg "VERSION=${VERSION}" \
  --build-arg "VCS_REF=${UPSTREAM_COMMIT}" \
  --build-arg "BUILD_DATE=${build_date}" \
  "$source_dir"

container_id=$(docker create "$image")
docker cp "${container_id}:/usr/local/bin/polkadot-rest-api" "$binary_path"
docker rm "$container_id" >/dev/null
container_id=''

[[ -f "$binary_path" && ! -L "$binary_path" ]] \
  || die "container output is a symlink or non-regular file"
chmod 0755 -- "$binary_path"
validate_elf "$binary_path"

binary_sha=$(sha256sum "$binary_path" | awk '{print $1}')
binary_size=$(stat -c '%s' -- "$binary_path")
(
  cd -- "$repo_root/dist"
  printf '%s  %s\n' "$binary_sha" "$binary" >"$checksum"
)

dockerfile_sha=$(sha256sum "${source_dir}/Dockerfile" | awk '{print $1}')
cargo_lock_sha=$(sha256sum "${source_dir}/Cargo.lock" | awk '{print $1}')
pinned_dockerfile_sha=$(sha256sum "$pinned_dockerfile" | awk '{print $1}')
run_id=${GITHUB_RUN_ID:-0}
run_attempt=${GITHUB_RUN_ATTEMPT:-0}
runner_image=${ImageOS:-ubuntu-24.04}

jq -n \
  --arg repository "$UPSTREAM_REPOSITORY" \
  --arg tag "$UPSTREAM_TAG" \
  --arg tag_object "$UPSTREAM_TAG_OBJECT" \
  --arg commit "$UPSTREAM_COMMIT" \
  --arg version "$VERSION" \
  --arg release_tag "$RELEASE_TAG" \
  --arg publisher_commit "$PUBLISHER_COMMIT" \
  --arg reviewed_at "$REVIEWED_AT" \
  --arg review_reference "$REVIEW_REFERENCE" \
  --arg dockerfile_sha "$dockerfile_sha" \
  --arg cargo_lock_sha "$cargo_lock_sha" \
  --arg builder "$BUILDER_BASE" \
  --arg runtime "$RUNTIME_BASE" \
  --arg pinned_dockerfile_sha "$pinned_dockerfile_sha" \
  --arg runner_image "$runner_image" \
  --arg run_id "$run_id" \
  --arg run_attempt "$run_attempt" \
  --arg build_date "$build_date" \
  --arg binary "$binary" \
  --arg sha "$binary_sha" \
  --argjson size "$binary_size" \
  '{
    schema: 1,
    upstream: {
      repository: $repository,
      tag: $tag,
      tag_object: $tag_object,
      commit: $commit,
      version: $version,
      signature_policy: "github-verified-annotated-tag"
    },
    release: {tag: $release_tag, publisher_commit: $publisher_commit},
    review: {reviewed_at: $reviewed_at, reference: $review_reference},
    source: {dockerfile_sha256: $dockerfile_sha, cargo_lock_sha256: $cargo_lock_sha},
    build: {
      builder_base: $builder,
      runtime_base: $runtime,
      pinned_dockerfile_sha256: $pinned_dockerfile_sha,
      runner_image: $runner_image,
      run_id: $run_id,
      run_attempt: $run_attempt,
      build_date: $build_date
    },
    artifact: {name: $binary, sha256: $sha, size: $size}
  }' >"$provenance_path"

bash "${script_dir}/validate-bundle.sh" "$repo_root/dist"
