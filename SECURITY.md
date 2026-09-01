# Publisher security operations

## One-time migration from the unsafe mirror design

Complete this checklist before re-enabling Actions:

1. Disable Actions for the repository and preserve the Actions/audit history.
   Inspect every run sourced from the old mirrored `main` branch or an upstream
   tag, and investigate unexpected network access or repository mutations.
2. Revoke the write deploy key in GitHub, remove the
   `MIRROR_SYNC_DEPLOY_KEY` Actions secret, and rotate the key if it has any
   remaining scope. Only after server-side revocation, delete plaintext local,
   backup, and CI copies that have no forensic retention requirement.
3. Archive the old `v0.2.0` release metadata, assets, hashes, tag target, and run
   logs as incident evidence. Mark it quarantined immediately. To prevent new
   downloads rather than merely warn, remove its assets/release after the archive
   is verified; remove its upstream-pointing tag as part of that operation.
4. Inventory every remote branch and tag. Delete the old upstream-mirrored
   `main` and upstream-pointing tags using explicit ref names after preserving
   the inventory. Do not replace them with other upstream workflow-bearing refs.
   If an exact mirror remains operationally necessary, place it in a different
   repository with Actions disabled and no secrets.
5. Push this trusted `ci` implementation, protect `ci` and
   `approved-releases.json` with required review/CODEOWNERS, set the default
   Actions token permission to read-only, allow only reviewed SHA-pinned actions,
   and enable immutable releases if the repository setting is available.
6. Re-enable Actions and manually dispatch the workflow. Adopt only the new
   `publisher-v0.2.0-r1` artifact after completing README.md's independent
   provenance and exact-artifact staging policy. Update all consumers away from
   the quarantined legacy release URL.

Rewriting `ci` history is not a substitute for this migration: GitHub retains
workflow/audit evidence, and deleting an exposed credential from Git history
does not revoke it. Rewrite only if secret bytes or other sensitive material are
found, then rotate them first and coordinate the force-push against branch rules.

## Approving a release

An approval is a deliberate security change, not discovery automation:

1. Review the upstream diff, release notes, Dockerfile, Cargo lockfile, and known
   vulnerabilities. Verify the annotated-tag signature and record both the tag
   object SHA and peeled commit.
2. Resolve the Dockerfile's linux/amd64 builder/runtime tags to immutable manifest
   digests. Add a new record to `approved-releases.json` with a new publisher
   revision tag. Never reuse a published publisher tag.
3. Obtain required review on the manifest and workflow/scripts. Merge to the
   protected `ci` branch, manually dispatch, and review the complete run.
4. Apply README.md's adoption policy before deployment.

## Revocation and upstream ref incidents

For a compromised, yanked, deleted, or moved upstream release:

1. Disable publication if an incident is active. Change the manifest record to
   `status: revoked`, set `revoked_at`, and give a specific
   `revocation_reason`; retain the record for forensic history.
2. Archive the release metadata, attestations, assets, hashes, and relevant logs.
   Quarantine the release visibly, then remove the downloadable assets/release
   once the archive is verified. The scheduled audit intentionally fails while
   a revoked release remains downloadable.
3. Notify consumers, invalidate deployment approvals, and replace the pinned
   hash only after a new source/security review and exact-artifact staging cycle.
4. Do not move, clobber, or silently reuse the old publisher tag. Publish a new
   revision and preserve the revocation record.

Any upstream tag-object or peeled-commit mismatch and any loss of GitHub's valid
signature status fails before build and again immediately before publication.
