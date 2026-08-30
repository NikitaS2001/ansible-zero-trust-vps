# v1.3.0 release notes

This release makes installation and publication independently verifiable. The installer accepts the official repository and SSH-signed `v1.3.0` tag, resolves that tag to its exact commit, and runs Ansible from that detached commit.

Release downloads contain the installer, its convenience checksum, an SPDX SBOM, the changelog, these notes, the upgrade guide, and `SHA256SUMS`. Every file has GitHub build-provenance attestation, and the published release is immutable.

GitHub Actions stops after creating and byte-verifying a draft. The maintainer publishes it locally with existing `gh` authentication only after confirming that release immutability is enabled.

Before upgrading an existing host, read `UPGRADE.md` and create an encrypted off-host backup.
