#!/usr/bin/env bash
# **************************************************************************** #
#   codegen-polyglot.sh — regenerate the Python + Dart client SDKs           #
# **************************************************************************** #
#
# A4: polyglot SDKs generated from the canonical OpenAPI 3.1 spec
#   apps/baas/mini-baas-infra/openapi/grobase-public.json
# into committed, regenerable packages:
#   apps/baas/sdk-python   (urllib3-based)
#   apps/baas/sdk-dart     (http-based)
#
# The hand-written TypeScript SDK (apps/baas/sdk) is the reference client and is
# NOT generated. Docker-first: openapi-generator runs in a container, so its
# layers land on the docker data-root (/mnt/storage), never the system disk;
# only the generated SOURCE is written into the repo.
#
# Usage:  bash apps/baas/sdk/scripts/codegen-polyglot.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # apps/baas/sdk/scripts
BAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"                # apps/baas
SPEC="mini-baas-infra/openapi/grobase-public.json"
IMG="${OPENAPI_GENERATOR_IMAGE:-openapitools/openapi-generator-cli:latest}"
VERSION="${SDK_VERSION:-0.2.0}"

[ -f "${BAAS_DIR}/${SPEC}" ] || { echo "spec not found: ${BAAS_DIR}/${SPEC}" >&2; exit 1; }

gen() { # $1 generator  $2 out-dir  $3 additional-properties
  # --user: write generated source as the host user (the image runs as root by
  # default, which would leave root-owned files in the repo that can't be cleaned
  # without sudo). Regenerating over a pre-existing dir: remove/mv it first.
  docker run --rm --user "$(id -u):$(id -g)" -v "${BAAS_DIR}:/work" "${IMG}" generate \
    -i "/work/${SPEC}" -g "$1" -o "/work/$2" \
    --additional-properties="$3"
}

echo "[codegen-polyglot] Python -> sdk-python"
gen python sdk-python "packageName=grobase,projectName=grobase-sdk,packageVersion=${VERSION},library=urllib3"

echo "[codegen-polyglot] Dart -> sdk-dart"
gen dart sdk-dart "pubName=grobase,pubVersion=${VERSION}"

echo "[codegen-polyglot] done — regenerated sdk-python + sdk-dart from ${SPEC}"
