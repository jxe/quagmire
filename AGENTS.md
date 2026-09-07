# Working in Quagmire

These instructions apply to the whole repository.

## Change discipline

- Keep Quagmire storage-, identity-, navigation-, and host-neutral. Product
  storage, durable identity, navigation policy, and presentation belong to
  consumers such as Arbor and Hunch.
- Preserve public API compatibility within a patch release. Before `1.0`, use a
  new minor version when intentionally changing the public contract.
- Keep changes focused and preserve unrelated working-tree changes.

## Verification

- Run the smallest focused tests while developing.
- Before declaring a revision releasable, run `scripts/verify.sh`. It runs the
  package tests and clean macOS and iOS Simulator builds for `Quagmire` and
  `QuagmireExtras`.
- Consumer integration is tested through local SwiftPM overrides before a
  release. Do not add a redundant post-tag remote-package build gate.

## Making a release

Quagmire releases are immutable Semantic Versioning tags. Arbor and Hunch keep
exact GitHub versions in their committed project metadata while local
development overrides those dependencies with this checkout.

1. Choose the next version: patch for compatible fixes, minor for an intentional
   pre-1.0 public API change, and major only for the explicit 1.0 compatibility
   commitment or a later breaking release.
2. Update the exact version in the README installation example, commit all
   intended release changes, and push `main`. Never release a dirty tree or move
   an existing tag.
3. Run `scripts/release.sh X.Y.Z`. This checks the branch and upstream revision,
   runs the full verification gate, and creates an annotated local tag.
4. Inspect the tag, then publish it with `scripts/release.sh X.Y.Z --push`.
5. In each consumer, update every committed exact-version pin to the new tag and
   commit the dependency bump separately. Keep using the consumer's local
   package override for subsequent development.

For Arbor, the two pins are in `native/project.yml` and
`native/Packages/ArborQuagmire/Package.swift`; regenerate the tracked Xcode
project from `native/project.yml` after changing them.
