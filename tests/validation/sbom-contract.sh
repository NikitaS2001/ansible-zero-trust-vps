#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sbom-contract.XXXXXX")"
trap 'rm -rf -- "${tmp}"' EXIT INT TERM

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
reject() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "accepted ${label}"; fi
    printf '[PASS] rejected %s\n' "${label}"
}

repo="${tmp}/repo"
mkdir -p "${repo}/scripts" \
    "${repo}/roles/vps_orchestration/defaults" \
    "${repo}/roles/vps_orchestration/templates"
cp "${ROOT_DIR}/scripts/build-spdx-sbom.sh" "${repo}/scripts/"
cp "${ROOT_DIR}/requirements.yml" "${repo}/"
cp "${ROOT_DIR}/roles/vps_orchestration/defaults/main.yml" \
    "${repo}/roles/vps_orchestration/defaults/main.yml"
cp "${ROOT_DIR}/roles/vps_orchestration/templates/docker-compose.yml.j2" \
    "${repo}/roles/vps_orchestration/templates/docker-compose.yml.j2"
git -C "${repo}" init -q
git -C "${repo}" config user.name fixture
git -C "${repo}" config user.email fixture@example.invalid
git -C "${repo}" add .
GIT_AUTHOR_DATE=1700000000 GIT_COMMITTER_DATE=1700000000 git -C "${repo}" commit -qm fixture
sha="$(git -C "${repo}" rev-parse HEAD)"

"${repo}/scripts/build-spdx-sbom.sh" --tag v9.9.9 --sha "${sha}" --output "${tmp}/one.json"
"${repo}/scripts/build-spdx-sbom.sh" --tag v9.9.9 --sha "${sha}" --output "${tmp}/two.json"
cmp "${tmp}/one.json" "${tmp}/two.json" >/dev/null || fail 'SBOM is not deterministic'
python3 - \
    "${tmp}/one.json" \
    "${sha}" \
    "${repo}/requirements.yml" \
    "${repo}/roles/vps_orchestration/defaults/main.yml" \
    "${repo}/roles/vps_orchestration/templates/docker-compose.yml.j2" <<'PY'
import copy
import json
import re
import sys
import yaml

sbom_path, sha, requirements_path, defaults_path, template_path = sys.argv[1:]
document = json.load(open(sbom_path, encoding="utf-8"))
requirements = yaml.safe_load(open(requirements_path, encoding="utf-8"))
defaults = yaml.safe_load(open(defaults_path, encoding="utf-8"))
template = open(template_path, encoding="utf-8").read()

expected_collections = {}
for entry in requirements["collections"]:
    constraint = entry["version"]
    assert constraint.startswith("==") and not constraint[2:].startswith("=")
    expected_collections[entry["name"]] = constraint[2:]

expected_images = set()
for candidate in re.findall(r"^\s*image:\s*(\S.*)$", template, re.MULTILINE):
    resolved = re.sub(
        r"{{\s*([a-z0-9_]+)\s*}}",
        lambda match: str(defaults[match.group(1)]),
        candidate,
    )
    assert "{{" not in resolved
    expected_images.add(resolved)

def validate(candidate):
    assert candidate["spdxVersion"] == "SPDX-2.3"
    assert candidate["name"] == "ansible-zero-trust-vps-v9.9.9"
    packages = candidate["packages"]
    ids = [package["SPDXID"] for package in packages]
    assert len(ids) == len(set(ids))
    source_packages = [item for item in packages if item["SPDXID"] == "SPDXRef-Package-Source"]
    assert len(source_packages) == 1
    source = source_packages[0]
    assert next(item["checksumValue"] for item in source["checksums"] if item["algorithm"] == "SHA1") == sha

    collections = [item for item in packages if item["SPDXID"].startswith("SPDXRef-Collection-")]
    actual_collections = {item["name"]: item["versionInfo"] for item in collections}
    assert actual_collections == expected_collections
    for item in collections:
        locator = item["externalRefs"][0]["referenceLocator"]
        assert locator == f'pkg:generic/{item["name"]}@{item["versionInfo"]}'
        assert "==" not in locator and not item["versionInfo"].startswith("=")

    images = [item for item in packages if item["SPDXID"].startswith("SPDXRef-OCI-")]
    assert {item["downloadLocation"] for item in images} == expected_images
    dependencies = collections + images
    assert len(packages) == 1 + len(dependencies)
    expected_relationships = {
        ("SPDXRef-DOCUMENT", "DESCRIBES", "SPDXRef-Package-Source"),
        *(("SPDXRef-Package-Source", "DEPENDS_ON", item["SPDXID"]) for item in dependencies),
    }
    actual_relationships = {
        (item["spdxElementId"], item["relationshipType"], item["relatedSpdxElement"])
        for item in candidate["relationships"]
    }
    assert actual_relationships == expected_relationships

validate(document)
dependency_ids = [
    item["SPDXID"] for item in document["packages"]
    if item["SPDXID"] != "SPDXRef-Package-Source"
]
assert dependency_ids
missing = copy.deepcopy(document)
missing["packages"] = [item for item in missing["packages"] if item["SPDXID"] != dependency_ids[0]]
extra = copy.deepcopy(document)
extra["packages"].append({
    "SPDXID": "SPDXRef-Unexpected",
    "name": "unexpected",
    "versionInfo": "1",
    "downloadLocation": "NOASSERTION",
})
for label, mutant in (("missing", missing), ("extra", extra)):
    try:
        validate(mutant)
    except AssertionError:
        continue
    raise AssertionError(f"accepted {label} SBOM component")
print(
    f"SBOM COMPONENT SET PASS collections={len(expected_collections)} "
    f"images={len(expected_images)} missing_rejected=true extra_rejected=true"
)
PY
[[ "$(stat -c %a "${tmp}/one.json")" == 600 ]] || fail 'SBOM mode is not 0600'
printf '[PASS] deterministic SPDX source and manifest-derived dependencies\n'

reject malformed-tag "${repo}/scripts/build-spdx-sbom.sh" \
    --tag latest --sha "${sha}" --output "${tmp}/bad.json"
reject stale-sha "${repo}/scripts/build-spdx-sbom.sh" \
    --tag v9.9.9 --sha 0000000000000000000000000000000000000000 --output "${tmp}/bad.json"
reject occupied-output "${repo}/scripts/build-spdx-sbom.sh" \
    --tag v9.9.9 --sha "${sha}" --output "${tmp}/one.json"

printf 'SBOM CONTRACT PASS sha=%s\n' "${sha}"
