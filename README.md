# polkadot-rest-api prebuilt binaries (release-build mirror)

**Looking for a polkadot-rest-api binary download?** Upstream [paritytech/polkadot-rest-api](https://github.com/paritytech/polkadot-rest-api), the Rust successor to Substrate API Sidecar (`substrate-api-sidecar`), publishes **source-only releases**; there are no official prebuilt binaries. This repository fills that gap: it automatically mirrors upstream and attaches a **prebuilt Linux x86_64 binary** to every upstream release tag, built by public CI from unmodified source. If you want to run the Polkadot REST API (for Polkadot, Kusama, Asset Hub / Polkadot Hub, Westend, or any Substrate chain it supports) without installing Docker or a Rust toolchain, grab it from the [**Releases page**](https://github.com/kk-hasuwae/polkadot-rest-api/releases).

> **Why this fork exists.** One reason only: turn upstream's source-only releases into downloadable, hash-verifiable binaries. The CI pipeline builds each upstream release tag with the repository's **own Dockerfile** (pinned Rust toolchain, Debian bookworm base), so the build is exactly what upstream defines, just executed in public CI instead of on your machine.
>
> **No source code is modified.** Branch `main` and every tag are unmodified mirrors of upstream. The only content unique to this fork lives on the `ci` branch: this README, the workflow in `.github/workflows/sync-and-release.yml`, and a `LAST_SYNC` timestamp.

## How it works

Once a day (and on manual dispatch), the `sync-and-release` workflow:

1. Fetches upstream and force-pushes `upstream/main` to `main`, plus all tags (pure mirror; local changes to `main` are intentionally impossible to keep).
2. Commits a `LAST_SYNC` timestamp on `ci` (GitHub auto-disables scheduled workflows after 60 days without repository activity; this keeps the schedule alive).
3. For every upstream tag `>= v0.2.0` that has no release with a binary asset here, it builds the tag with the repo's own `Dockerfile` on an `ubuntu-24.04` runner, extracts `/usr/local/bin/polkadot-rest-api`, and publishes a release with two assets:
   - `polkadot-rest-api-<tag>-linux-x86_64`
   - `polkadot-rest-api-<tag>-linux-x86_64.sha256`

The release notes record the upstream commit and the builder base-image digest for provenance.

## Download and verify a release binary

```bash
TAG=v0.2.0
BASE=https://github.com/kk-hasuwae/polkadot-rest-api/releases/download/${TAG}
curl -fLO "${BASE}/polkadot-rest-api-${TAG}-linux-x86_64"
curl -fLO "${BASE}/polkadot-rest-api-${TAG}-linux-x86_64.sha256"
sha256sum -c "polkadot-rest-api-${TAG}-linux-x86_64.sha256"
```

The binary is built on Debian bookworm (glibc 2.36), so it runs on any distro with glibc >= 2.36 (Ubuntu 22.04+, Debian 12+).

## Trust model

- The release is **transport, not trust**: consumers must pin the expected sha256 out-of-band (e.g. in their deployment runbook, recorded when the artifact is first validated) rather than trusting whatever the release currently serves. The `.sha256` asset is a convenience for the initial recording, not a security boundary; anyone who can alter the binary asset can alter it too.
- Provenance chain: upstream tag -> mirrored tag (same commit hash, verifiable against upstream) -> Actions build log (public) -> release asset.
- Builds are not guaranteed byte-reproducible across time: the upstream Dockerfile uses a mutable base-image tag and unpinned apt packages. Each release therefore records the base-image digest actually used.

## Branch layout

| Branch | Content                                                   |
| ------ | --------------------------------------------------------- |
| `ci`   | **default**; this README + the workflow + `LAST_SYNC` only |
| `main` | pure mirror of upstream `main` (force-updated; do not commit here) |

`ci` is the default branch because scheduled workflows only run from the default branch, and keeping the workflow off `main` lets the mirror force-push without ever colliding with CI files.

## Operations notes

- This is a GitHub **fork**, so scheduled workflows are disabled until enabled once in the **Actions** tab.
- Manual run: **Actions -> Sync upstream and release binaries -> Run workflow** (builds any missing tags immediately).
- To raise the oldest tag that gets built, change `MIN_TAG` in the workflow.
