#!/usr/bin/env bash

set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
# shellcheck source=release-common.sh
source "${script_dir}/release-common.sh"

validate_release_environment
[[ $(git -C "$repo_root" rev-parse HEAD) == "$PUBLISHER_COMMIT" ]] \
  || die "trusted publisher scripts do not match the workflow commit"
verify_upstream_approval
bash "${script_dir}/validate-bundle.sh" "$repo_root/dist"

binary=$(binary_name)
checksum=$(checksum_name)
provenance=$(provenance_name)
binary_path="${repo_root}/dist/${binary}"
checksum_path="${repo_root}/dist/${checksum}"
provenance_path="${repo_root}/dist/${provenance}"
binary_sha=$(sha256sum "$binary_path" | awk '{print $1}')
revision=${RELEASE_TAG##*-r}
run_marker="Publisher run: ${GITHUB_RUN_ID}/${GITHUB_RUN_ATTEMPT}"
notes=$(mktemp)
download_dir=$(mktemp -d)
cleanup_draft=true

cleanup() {
  local metadata tag_ref
  rm -f -- "$notes"
  rm -rf -- "$download_dir"
  if [[ "$cleanup_draft" != true ]]; then
    return
  fi

  # Roll back only a draft carrying this run's unique marker. This avoids a
  # permanently partial release while refusing to touch an unrelated release.
  if metadata=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
      --json isDraft,body 2>/dev/null); then
    if jq -e --arg marker "$run_marker" \
        '.isDraft == true and (.body | contains($marker))' <<<"$metadata" >/dev/null; then
      gh release delete "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --yes --cleanup-tag \
        >/dev/null 2>&1 || true
    fi
    return
  fi

  # gh may create the tag before a failed release request. The preflight below
  # established that it did not exist before this run, so remove only a tag
  # still pointing at this exact trusted publisher commit.
  if tag_ref=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}" 2>/dev/null); then
    if jq -e --arg sha "$PUBLISHER_COMMIT" \
        '.object.type == "commit" and .object.sha == $sha' <<<"$tag_ref" >/dev/null; then
      gh api --method DELETE "repos/${GITHUB_REPOSITORY}/git/refs/tags/${RELEASE_TAG}" \
        >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

if preflight=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" 2>&1); then
  die "release ${RELEASE_TAG} appeared after planning; immutable publication refuses to replace it"
fi
grep -Eq 'release not found|\(HTTP 404\)' <<<"$preflight" \
  || die "could not confirm release absence: ${preflight}"
if preflight=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}" 2>&1); then
  die "tag ${RELEASE_TAG} appeared after planning; publication refuses to move it"
fi
grep -Fq '(HTTP 404)' <<<"$preflight" \
  || die "could not confirm publisher-tag absence: ${preflight}"

cat >"$notes" <<EOF
Approved, unmodified upstream source built with pinned base-image manifests.

- Upstream repository: ${UPSTREAM_REPOSITORY}
- Upstream tag: ${UPSTREAM_TAG}
- Upstream tag object: ${UPSTREAM_TAG_OBJECT}
- Upstream commit: ${UPSTREAM_COMMIT}
- Upstream signature policy: GitHub-verified annotated tag
- Source/security review: ${REVIEWED_AT} — ${REVIEW_REFERENCE}
- Publisher workflow commit: ${PUBLISHER_COMMIT}
- Builder base: ${BUILDER_BASE}
- Runtime base: ${RUNTIME_BASE}
- Binary SHA-256: ${binary_sha}
- ${run_marker}

This release is immutable. The publisher tag points to trusted publisher code,
not upstream source. Upstream identity is carried only as verified provenance.

Verify the checksum and GitHub artifact attestation as described in README.md.
EOF

gh release create "$RELEASE_TAG" \
  "$binary_path" "$checksum_path" "$provenance_path" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$PUBLISHER_COMMIT" \
  --title "polkadot-rest-api ${UPSTREAM_TAG} (publisher revision ${revision})" \
  --notes-file "$notes" \
  --draft \
  --latest=false

metadata=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json tagName,targetCommitish,isDraft,isPrerelease,body,assets)
jq -e \
  --arg tag "$RELEASE_TAG" \
  --arg target "$PUBLISHER_COMMIT" \
  --arg binary "$binary" \
  --arg checksum "$checksum" \
  --arg provenance "$provenance" \
  '.tagName == $tag and .targetCommitish == $target and
   .isDraft == true and .isPrerelease == false and
   ([.assets[].name] | sort) == ([$binary, $checksum, $provenance] | sort) and
   all(.assets[]; .size > 0)' <<<"$metadata" >/dev/null \
  || die "draft release metadata or exact asset set failed validation"

gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --dir "$download_dir" \
  --pattern "$binary" --pattern "$checksum" --pattern "$provenance"
bash "${script_dir}/validate-bundle.sh" "$download_dir"
for name in "$binary" "$checksum" "$provenance"; do
  [[ $(sha256sum "${download_dir}/${name}" | awk '{print $1}') == \
     $(sha256sum "${repo_root}/dist/${name}" | awk '{print $1}') ]] \
    || die "uploaded asset ${name} differs from the validated local bundle"
done

gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false
published=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
  --json isDraft,tagName,targetCommitish)
jq -e --arg tag "$RELEASE_TAG" --arg target "$PUBLISHER_COMMIT" \
  '.isDraft == false and .tagName == $tag and .targetCommitish == $target' \
  <<<"$published" >/dev/null || die "release did not become a stable immutable publication"

cleanup_draft=false
printf 'Published immutable release %s for upstream %s at %s\n' \
  "$RELEASE_TAG" "$UPSTREAM_TAG" "$UPSTREAM_COMMIT"
