# polkadot-rest-api reviewed binary publisher

This repository publishes Linux x86-64 binaries for selected releases of
[paritytech/polkadot-rest-api](https://github.com/paritytech/polkadot-rest-api).
Upstream publishes source releases, not official prebuilt binaries.

This is a publisher, not a source mirror. Upstream branches, tags, and workflow
files are deliberately not pushed here. Every build must first be added to
[`approved-releases.json`](approved-releases.json) with a reviewed stable SemVer
tag, GitHub-verified annotated-tag object, peeled commit, immutable builder and
runtime image manifests, and source/security review record.

## Download and verify

Publisher tags are intentionally distinct from upstream tags. For upstream
`v0.2.0`, publisher revision 1 is `publisher-v0.2.0-r1`:

```bash
UPSTREAM_TAG=v0.2.0
RELEASE_TAG=publisher-v0.2.0-r1
REPO=mkdior/polkadot-rest-api
ASSET=polkadot-rest-api-${UPSTREAM_TAG}-linux-x86_64

gh release download "${RELEASE_TAG}" --repo "${REPO}" \
  --pattern "${ASSET}" \
  --pattern "${ASSET}.sha256" \
  --pattern "${ASSET}.provenance.json"
sha256sum -c "${ASSET}.sha256"
gh attestation verify "${ASSET}" \
  --repo "${REPO}" \
  --signer-workflow "${REPO}/.github/workflows/sync-and-release.yml"
```

The exact release asset set is:

- `polkadot-rest-api-<upstream-tag>-linux-x86_64`
- the matching `.sha256`
- the matching `.provenance.json`

The provenance records the signed upstream tag object and commit, publisher
workflow commit, reviewed base-image digests, source-input hashes, build run,
artifact size, and artifact SHA-256. Also confirm that the publisher release tag
points to the recorded publisher commit. It points to trusted code on `main`, never
to upstream source.

## Mandatory adoption policy

The co-located checksum establishes consistency, not independent trust. Before a
new publisher revision is used in production:

1. Review the exact upstream source commit and Dockerfile, the signed upstream
   tag, and the publisher commit that approved it.
2. Review the public build log and provenance. Verify the artifact attestation
   names this repository and `.github/workflows/sync-and-release.yml`; confirm
   its workflow ref/commit is the publisher commit recorded in provenance.
3. Download and hash the binary independently. Record its SHA-256, upstream tag
   object/commit, publisher commit, and Actions run outside this repository.
4. Install this exact artifact in staging and complete the required soak and
   security/functional checks. A same-version, separately built binary does not
   satisfy this requirement.
5. Run the service as a dedicated least-privilege identity, not as a node or
   other application account. Apply systemd hardening such as `NoNewPrivileges`,
   `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp=true`, and
   `RestrictSUIDSGID=true`, adjusted only for documented runtime needs.

The binary should still be pinned by its independently adopted SHA-256 in every
deployment. GitHub transport, release notes, provenance, checksum, and
attestation are complementary evidence; none replaces source review and exact
artifact staging.

## Publisher design

The scheduled/manual workflow performs three separated phases:

1. A read-only audit validates each approval against the live upstream signed
   tag and audits any existing release's exact assets and hashes. New upstream
   stable tags are listed only as a human review queue.
2. A bounded, read-only job builds at most two approved releases serially, with
   a 45-minute timeout. It fetches the pinned commit, substitutes only the two
   reviewed base-image manifests, and rejects symlinks, special files, implausible
   sizes, and non-x86-64 ELF output without executing the binary.
3. A fresh, trusted publication job is the only job with `contents: write`. It
   treats the transferred bundle strictly as data, revalidates it without
   execution, generates GitHub artifact attestations, and creates a draft. The
   exact uploaded files are downloaded and compared before publication.

Published releases are never clobbered or rebuilt in place. A changed build gets
a new publisher revision. Upstream tag movement/deletion, signature failure,
release drift, partial assets, or a revoked release still being downloadable
fails the audit. All third-party actions are pinned to reviewed full commit SHAs.

The upstream Dockerfile still installs packages from mutable Debian repositories,
so builds are not guaranteed byte-reproducible even though its base images and
Cargo lockfile are pinned/recorded. This is why publisher revisions are immutable
and adoption pins an independently reviewed artifact hash.

See [SECURITY.md](SECURITY.md) for migration, revocation, and incident procedures.

## Branch and operations model

Only the trusted `main` publisher branch is required. There is no deploy key and no
automated keepalive commit. GitHub may disable schedules in an inactive public
repository; manually dispatch the audit after approving a release and monitor
the schedule explicitly. Scheduled runs audit provenance and upstream movement;
they do not approve or auto-publish arbitrary new tags.
