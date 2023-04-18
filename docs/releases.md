# Tackle Upstream Release Instructions

## Prerequisites

- Podman 1.6.4+
- [Operator SDK v1.3.0+](https://github.com/operator-framework/operator-sdk)
- [Opm](https://github.com/operator-framework/operator-registry) for index image manipulation
- [Quay.io](https://quay.io/organization/konveyor) access to Konveyor Tackle2 repos

## Overview
The Konveyor Tackle2 new release procedure consist of a few steps summarized below:
- Create a new release branch on Konveyor Tackle2 Operator repo
- Create and submit PR preparing bundle manifests for the new release branch
- Once merged, bundle images for new release will be automatically built on Quay.io
- Build new index images and push new metadata to Quay.io

## Stable
We use semantic versioning convention (semver) for stable releases, release branches should be in the form of v<semver>

1. Create a new release branch in Tackle2 operator repo, for example `v2.0.0`
1. Create a PR for the new release branch
   1. Run `tools/cut-release.py --version 2.0.0 --project-path .`
   1. Review changes, commmit, and submit the PR against new release branch for review
1. Once the release PR is ready and merged, add it to the index image and push to quay.io
   1. `tools/push-release-metadata.py --old-version 1.9.9 --new-version 2.0.0`
   1. Create or refresh existing konveyor-tackle catalog source and validate `oc create -f konveyor-operator-catalog.yaml`
