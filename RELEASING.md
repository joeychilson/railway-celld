# Releasing

This repository versions the Railway wrapper independently from celld. A new
upstream version does not force the wrapper to use the same version number.

Use semantic versioning for the wrapper:

- Patch: compatible upstream and dependency updates or wrapper fixes.
- Minor: new, backward-compatible template behavior or configuration.
- Major: changes that require users to update configuration or migrate data.

To publish an image:

1. Merge the change and confirm `ci.yml` passes on `main`.
2. Create a GitHub release tagged `vX.Y.Z`.
3. Include the celld version in the release title or notes, such as
   `v1.0.0 — celld 0.3.0`.
4. Confirm `release.yml` publishes the multi-platform image.
5. When starting a new major or minor line, update the public Railway
   template's source image to `ghcr.io/joeychilson/railway-celld:X.Y` only
   after that image has been published successfully.

Each release publishes immutable `X.Y.Z` and `sha-<commit>` tags, a moving
`X.Y` patch channel, and a `celld-<version>` compatibility tag. No `latest`
tag is published. Railway templates should reference `X.Y` when compatible
patch updates should be automatic, or `X.Y.Z` when the image must stay fixed.
Changing the public template affects future deployments only. Existing
Docker-image deployments keep their configured image tag.
