#!/usr/bin/env bash

set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/../.." && pwd)
# shellcheck source=release-common.sh
source "${script_dir}/release-common.sh"

manifest="${repo_root}/approved-releases.json"
[[ -f "$manifest" && ! -L "$manifest" ]] || die "approved-releases.json is missing or unsafe"
[[ $(git -C "$repo_root" rev-parse HEAD) == "$PUBLISHER_COMMIT" ]] \
  || die "the checked-out publisher code does not match the workflow commit"

jq -e '
  .schema == 1 and
  (.max_builds_per_run | type == "number" and . >= 1 and . <= 5 and floor == .) and
  (.releases | type == "array") and
  ([keys[]] | sort) == (["max_builds_per_run", "releases", "schema"] | sort) and
  all(.releases[];
    ([keys[]] | sort) == ([
      "builder_base", "release_tag", "review_reference", "reviewed_at",
      "revocation_reason", "revoked_at", "runtime_base", "status",
      "upstream_commit", "upstream_tag", "upstream_tag_object", "version"
    ] | sort) and
    (.status == "approved" or .status == "revoked") and
    ([.upstream_tag, .upstream_tag_object, .upstream_commit, .version,
      .release_tag, .builder_base, .runtime_base, .reviewed_at,
      .review_reference] | all(type == "string" and length > 0)) and
    (if .status == "approved" then
       .revoked_at == null and .revocation_reason == null
     else
       (.revoked_at | type == "string" and test("^20[0-9]{2}-[01][0-9]-[0-3][0-9]$")) and
       (.revocation_reason | type == "string" and length > 0)
     end)
  ) and
  (([.releases[].upstream_tag] | unique | length) == (.releases | length)) and
  (([.releases[].release_tag] | unique | length) == (.releases | length))
' "$manifest" >/dev/null || die "approved-releases.json failed its closed schema"

max_builds=$(jq -r '.max_builds_per_run' "$manifest")
pending_file=$(mktemp)
trap 'rm -f -- "$pending_file"' EXIT

load_release_environment() {
  local row=$1
  export UPSTREAM_TAG UPSTREAM_TAG_OBJECT UPSTREAM_COMMIT VERSION RELEASE_TAG
  export BUILDER_BASE RUNTIME_BASE REVIEWED_AT REVIEW_REFERENCE
  UPSTREAM_TAG=$(jq -r '.upstream_tag' <<<"$row")
  UPSTREAM_TAG_OBJECT=$(jq -r '.upstream_tag_object' <<<"$row")
  UPSTREAM_COMMIT=$(jq -r '.upstream_commit' <<<"$row")
  VERSION=$(jq -r '.version' <<<"$row")
  RELEASE_TAG=$(jq -r '.release_tag' <<<"$row")
  BUILDER_BASE=$(jq -r '.builder_base' <<<"$row")
  RUNTIME_BASE=$(jq -r '.runtime_base' <<<"$row")
  REVIEWED_AT=$(jq -r '.reviewed_at' <<<"$row")
  REVIEW_REFERENCE=$(jq -r '.review_reference' <<<"$row")
}

read_release() {
  local output
  if output=$(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
      --json tagName,targetCommitish,isDraft,isPrerelease,body,assets 2>&1); then
    printf '%s' "$output"
    return 0
  fi
  # gh release view reports a missing release as "release not found"; only
  # gh api failures carry the "(HTTP 404)" form. Callers run this inside a
  # command substitution, where die cannot stop the job, so unrecognized
  # errors are a distinct status the caller must turn into a hard failure.
  if grep -Eq 'release not found|\(HTTP 404\)' <<<"$output"; then
    return 1
  fi
  printf 'ERROR: could not inspect release %s: %s\n' "$RELEASE_TAG" "$output" >&2
  return 2
}

assert_publisher_tag_absent() {
  local output
  if output=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}" 2>&1); then
    die "publisher tag ${RELEASE_TAG} exists without its immutable release"
  fi
  grep -Fq '(HTTP 404)' <<<"$output" \
    || die "could not inspect publisher tag ${RELEASE_TAG}: ${output}"
}

validate_existing_release() {
  local metadata=$1 tag_ref safe_sha comparison body temp_dir binary checksum provenance
  binary=$(binary_name)
  checksum=$(checksum_name)
  provenance=$(provenance_name)

  jq -e \
    --arg tag "$RELEASE_TAG" \
    --arg binary "$binary" \
    --arg checksum "$checksum" \
    --arg provenance "$provenance" \
    '.tagName == $tag and .isDraft == false and .isPrerelease == false and
     ([.assets[].name] | sort) == ([$binary, $checksum, $provenance] | sort) and
     all(.assets[]; .size > 0)' <<<"$metadata" >/dev/null \
    || die "release ${RELEASE_TAG} is draft, prerelease, or has a non-exact asset set"

  tag_ref=$(gh api "repos/${GITHUB_REPOSITORY}/git/ref/tags/${RELEASE_TAG}") \
    || die "release ${RELEASE_TAG} has no readable publisher tag"
  [[ $(jq -r '.object.type' <<<"$tag_ref") == commit ]] \
    || die "publisher tag ${RELEASE_TAG} must be a lightweight tag on trusted code"
  safe_sha=$(jq -r '.object.sha' <<<"$tag_ref")
  [[ "$safe_sha" =~ ^[0-9a-f]{40}$ ]] || die "publisher tag has an invalid target"

  comparison=$(gh api "repos/${GITHUB_REPOSITORY}/compare/${safe_sha}...${PUBLISHER_COMMIT}" --jq '.status') \
    || die "could not compare publisher tag with the trusted publisher branch"
  [[ "$comparison" == ahead || "$comparison" == identical ]] \
    || die "publisher tag ${RELEASE_TAG} is not on trusted publisher-branch history"
  jq -e --arg sha "$safe_sha" '.targetCommitish == $sha' <<<"$metadata" >/dev/null \
    || die "release targetCommitish does not match its publisher-owned tag"

  body=$(jq -r '.body' <<<"$metadata")
  grep -Fqx -- "- Upstream tag: ${UPSTREAM_TAG}" <<<"$body" \
    || die "release notes have the wrong upstream tag"
  grep -Fqx -- "- Upstream tag object: ${UPSTREAM_TAG_OBJECT}" <<<"$body" \
    || die "release notes have the wrong upstream tag object"
  grep -Fqx -- "- Upstream commit: ${UPSTREAM_COMMIT}" <<<"$body" \
    || die "release notes have the wrong upstream commit"
  grep -Fqx -- "- Publisher workflow commit: ${safe_sha}" <<<"$body" \
    || die "release notes have the wrong publisher commit"

  temp_dir=$(mktemp -d)
  gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --dir "$temp_dir" \
    --pattern "$binary" --pattern "$checksum" --pattern "$provenance" \
    || die "could not download the exact immutable asset set"
  PUBLISHER_COMMIT="$safe_sha" bash "${script_dir}/validate-bundle.sh" "$temp_dir"
  rm -rf -- "$temp_dir"
}

while IFS= read -r row; do
  load_release_environment "$row"
  validate_release_environment
  status=$(jq -r '.status' <<<"$row")

  if [[ "$status" == revoked ]]; then
    if metadata=$(read_release); then
      die "revoked release ${RELEASE_TAG} is still published; quarantine it and remove its downloadable assets"
    else
      [[ $? -eq 1 ]] || die "could not confirm revoked release ${RELEASE_TAG} is unpublished"
    fi
    continue
  fi

  verify_upstream_approval
  if metadata=$(read_release); then
    validate_existing_release "$metadata"
    printf 'Existing release %s is complete, immutable, and matches provenance.\n' "$RELEASE_TAG"
  else
    [[ $? -eq 1 ]] || die "could not confirm release ${RELEASE_TAG} absence"
    assert_publisher_tag_absent
    printf '%s\n' "$row" >>"$pending_file"
  fi
done < <(jq -c '.releases[]' "$manifest")

pending_count=$(wc -l <"$pending_file")
(( pending_count <= max_builds )) \
  || die "${pending_count} approved builds exceed the per-run cap of ${max_builds}"
if (( pending_count == 0 )); then
  releases='[]'
else
  releases=$(jq -cs '.' "$pending_file")
fi
printf 'releases=%s\n' "$releases" >>"$GITHUB_OUTPUT"

# Discover stable tags only as a human review queue. They are never added to the
# build matrix until a reviewed manifest commit pins all provenance fields.
approved_tags=$(mktemp)
remote_tags=$(mktemp)
trap 'rm -f -- "$pending_file" "$approved_tags" "$remote_tags"' EXIT
jq -r '.releases[].upstream_tag' "$manifest" | sort -u >"$approved_tags"
git ls-remote --tags "$UPSTREAM_URL" \
  | awk '{ sub(/\^\{\}$/, "", $2); sub(/^refs\/tags\//, "", $2); print $2 }' \
  | sort -u \
  | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  >"$remote_tags" || true

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
{
  printf '## Publisher audit\n\n'
  printf -- '- Approved builds queued: %s (cap: %s)\n' "$pending_count" "$max_builds"
  unreviewed_count=$(comm -23 "$remote_tags" "$approved_tags" | wc -l)
  printf -- '- Stable upstream tags awaiting review: %s\n' "$unreviewed_count"
  if (( unreviewed_count > 0 )); then
    printf '\nNo unreviewed tag is built automatically. First 20 entries:\n\n'
    comm -23 "$remote_tags" "$approved_tags" | head -20 | sed 's/^/- `/' | sed 's/$/`/'
  fi
} >>"$summary"
