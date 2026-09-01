#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=C

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_release_environment() {
  local name
  for name in \
    UPSTREAM_REPOSITORY UPSTREAM_URL PUBLISHER_COMMIT UPSTREAM_TAG \
    UPSTREAM_TAG_OBJECT UPSTREAM_COMMIT VERSION RELEASE_TAG BUILDER_BASE \
    RUNTIME_BASE REVIEWED_AT REVIEW_REFERENCE; do
    [[ -n "${!name:-}" ]] || die "required environment variable ${name} is empty"
  done
}

validate_release_environment() {
  require_release_environment

  # Intentionally accept stable SemVer only. Supporting prereleases requires a
  # reviewed policy change; arbitrary v* refs never become shell or Docker data.
  [[ "$UPSTREAM_TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "upstream tag is outside the stable SemVer policy: ${UPSTREAM_TAG}"
  [[ "$VERSION" == "${UPSTREAM_TAG#v}" ]] \
    || die "version ${VERSION} does not match tag ${UPSTREAM_TAG}"
  [[ "$RELEASE_TAG" =~ ^publisher-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-r[1-9][0-9]*$ ]] \
    || die "unsafe publisher release tag: ${RELEASE_TAG}"
  [[ "$UPSTREAM_TAG_OBJECT" =~ ^[0-9a-f]{40}$ ]] \
    || die "invalid upstream tag-object SHA"
  [[ "$UPSTREAM_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "invalid upstream commit SHA"
  [[ "$PUBLISHER_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "invalid publisher commit SHA"
  [[ "$BUILDER_BASE" =~ ^docker\.io/library/rust:[0-9A-Za-z._-]+@sha256:[0-9a-f]{64}$ ]] \
    || die "builder image is not an immutable official-library Rust reference"
  [[ "$RUNTIME_BASE" =~ ^docker\.io/library/debian:[0-9A-Za-z._-]+@sha256:[0-9a-f]{64}$ ]] \
    || die "runtime image is not an immutable official-library Debian reference"
  [[ "$REVIEWED_AT" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]$ ]] \
    || die "invalid review date"
  [[ ${#REVIEW_REFERENCE} -le 240 && "$REVIEW_REFERENCE" != *$'\n'* && "$REVIEW_REFERENCE" != *$'\r'* ]] \
    || die "invalid review reference"
}

binary_name() {
  printf 'polkadot-rest-api-%s-linux-x86_64' "$UPSTREAM_TAG"
}

checksum_name() {
  printf '%s.sha256' "$(binary_name)"
}

provenance_name() {
  printf '%s.provenance.json' "$(binary_name)"
}

verify_upstream_approval() {
  local refs direct peeled tag_json

  refs=$(git ls-remote "$UPSTREAM_URL" \
    "refs/tags/${UPSTREAM_TAG}" "refs/tags/${UPSTREAM_TAG}^{}") \
    || die "could not read upstream tag ${UPSTREAM_TAG}"
  direct=$(awk -v ref="refs/tags/${UPSTREAM_TAG}" '$2 == ref { print $1 }' <<<"$refs")
  peeled=$(awk -v ref="refs/tags/${UPSTREAM_TAG}^{}" '$2 == ref { print $1 }' <<<"$refs")

  [[ "$direct" == "$UPSTREAM_TAG_OBJECT" ]] \
    || die "upstream tag ${UPSTREAM_TAG} was deleted or moved (tag object ${direct:-missing})"
  [[ "$peeled" == "$UPSTREAM_COMMIT" ]] \
    || die "upstream tag ${UPSTREAM_TAG} no longer peels to the approved commit"

  tag_json=$(gh api "repos/${UPSTREAM_REPOSITORY}/git/tags/${UPSTREAM_TAG_OBJECT}") \
    || die "could not retrieve GitHub verification for ${UPSTREAM_TAG_OBJECT}"
  jq -e \
    --arg tag "$UPSTREAM_TAG" \
    --arg tag_object "$UPSTREAM_TAG_OBJECT" \
    --arg commit "$UPSTREAM_COMMIT" \
    '.sha == $tag_object and .tag == $tag and
     .object.type == "commit" and .object.sha == $commit and
     .verification.verified == true and .verification.reason == "valid"' \
    <<<"$tag_json" >/dev/null \
    || die "upstream annotated-tag signature is not GitHub-verified and valid"
}

validate_elf() {
  local path=$1 size header

  [[ -f "$path" && ! -L "$path" ]] || die "binary is not a regular non-symlink file"
  size=$(stat -c '%s' -- "$path")
  (( size >= 1048576 && size <= 536870912 )) \
    || die "binary size ${size} is outside the 1 MiB..512 MiB policy"
  header=$(readelf -h -- "$path") || die "binary has no readable ELF header"
  grep -Eq '^  Class:[[:space:]]+ELF64$' <<<"$header" || die "binary is not ELF64"
  grep -Eq '^  Data:[[:space:]]+2.s complement, little endian$' <<<"$header" \
    || die "binary is not little-endian"
  grep -Eq '^  Type:[[:space:]]+(DYN|EXEC)' <<<"$header" || die "binary is not executable ELF"
  grep -Eq '^  Machine:[[:space:]]+Advanced Micro Devices X86-64$' <<<"$header" \
    || die "binary is not x86-64"
  file -b -- "$path" | grep -Eq '^ELF 64-bit LSB (pie )?executable, x86-64,' \
    || die "file(1) rejected the expected Linux x86-64 executable type"
}
