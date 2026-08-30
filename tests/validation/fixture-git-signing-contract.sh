#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly ROOT_DIR

env \
    GIT_CONFIG_COUNT=3 \
    GIT_CONFIG_KEY_0=commit.gpgsign \
    GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=gpg.format \
    GIT_CONFIG_VALUE_1=ssh \
    GIT_CONFIG_KEY_2=user.signingkey \
    GIT_CONFIG_VALUE_2=/definitely/missing/f2-signing-key \
    "${ROOT_DIR}/tests/validation/sbom-contract.sh"

printf 'fixture-git-signing-contract: inherited signing isolation PASS\n'
