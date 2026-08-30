# Upgrade to v1.3.0

1. Create and verify an encrypted off-host backup.
2. Download all seven assets from the immutable `v1.3.0` GitHub release.
3. For every downloaded file, run `gh attestation verify <file> --repo NikitaS2001/ansible-zero-trust-vps --signer-workflow NikitaS2001/ansible-zero-trust-vps/.github/workflows/release.yml --source-ref refs/tags/v1.3.0`.
4. Run `sha256sum --check SHA256SUMS` and confirm that `install.sh.sha256` equals the `install.sh` row in `SHA256SUMS`.
5. Run the verified `install.sh` and keep the original SSH session open until post-install checks pass.
6. Confirm SSH, WireGuard, DNS, HTTPS, firewall policy, monitoring, and backup operation.

If validation fails, stop and restore the pre-upgrade backup. Never move or reuse a failed release tag.
