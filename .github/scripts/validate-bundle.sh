#!/usr/bin/env bash

set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=release-common.sh
source "${script_dir}/release-common.sh"

bundle_dir=${1:-dist}
validate_release_environment

binary=$(binary_name)
checksum=$(checksum_name)
provenance=$(provenance_name)
binary_path="${bundle_dir}/${binary}"
checksum_path="${bundle_dir}/${checksum}"
provenance_path="${bundle_dir}/${provenance}"

[[ -d "$bundle_dir" && ! -L "$bundle_dir" ]] || die "bundle directory is missing or a symlink"
mapfile -d '' entries < <(find "$bundle_dir" -mindepth 1 -maxdepth 1 -print0)
[[ ${#entries[@]} -eq 3 ]] || die "bundle must contain exactly three entries"
for path in "$binary_path" "$checksum_path" "$provenance_path"; do
  [[ -f "$path" && ! -L "$path" ]] || die "unexpected or unsafe bundle entry: ${path}"
done

validate_elf "$binary_path"

[[ $(wc -l <"$checksum_path") -eq 1 ]] || die "checksum file must contain exactly one line"
expected_sha=$(sha256sum "$binary_path" | awk '{print $1}')
expected_line="${expected_sha}  ${binary}"
[[ $(<"$checksum_path") == "$expected_line" ]] || die "checksum file is malformed or mismatched"
(
  cd -- "$bundle_dir"
  sha256sum -c -- "$checksum"
) >/dev/null

binary_size=$(stat -c '%s' -- "$binary_path")
jq -e \
  --arg repository "$UPSTREAM_REPOSITORY" \
  --arg tag "$UPSTREAM_TAG" \
  --arg tag_object "$UPSTREAM_TAG_OBJECT" \
  --arg commit "$UPSTREAM_COMMIT" \
  --arg version "$VERSION" \
  --arg release_tag "$RELEASE_TAG" \
  --arg builder "$BUILDER_BASE" \
  --arg runtime "$RUNTIME_BASE" \
  --arg reviewed_at "$REVIEWED_AT" \
  --arg review_reference "$REVIEW_REFERENCE" \
  --arg publisher_commit "$PUBLISHER_COMMIT" \
  --arg binary "$binary" \
  --arg sha "$expected_sha" \
  --argjson size "$binary_size" \
  '.schema == 1 and
   .upstream.repository == $repository and
   .upstream.tag == $tag and
   .upstream.tag_object == $tag_object and
   .upstream.commit == $commit and
   .upstream.version == $version and
   .upstream.signature_policy == "github-verified-annotated-tag" and
   .release.tag == $release_tag and
   .release.publisher_commit == $publisher_commit and
   .review.reviewed_at == $reviewed_at and
   .review.reference == $review_reference and
   .build.builder_base == $builder and
   .build.runtime_base == $runtime and
   .artifact.name == $binary and
   .artifact.sha256 == $sha and
   .artifact.size == $size and
   (.source.dockerfile_sha256 | test("^[0-9a-f]{64}$")) and
   (.source.cargo_lock_sha256 | test("^[0-9a-f]{64}$")) and
   (.build.pinned_dockerfile_sha256 | test("^[0-9a-f]{64}$")) and
   (.build.runner_image | type == "string" and length > 0) and
   (.build.run_id | test("^[0-9]+$")) and
   (.build.run_attempt | test("^[0-9]+$"))' \
  "$provenance_path" >/dev/null \
  || die "provenance file does not match the approved release and artifact"

printf 'Validated %s (%s bytes, sha256 %s)\n' "$binary" "$binary_size" "$expected_sha"
