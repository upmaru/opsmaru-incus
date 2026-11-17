#!/usr/bin/env bash
# Builds the release cassette and its SHA-256 file:
#
#   OUTPUT_DIR/opsmaru_incus-VERSION.tama-cassette
#   OUTPUT_DIR/opsmaru_incus-VERSION.tama-cassette.sha256
#
# The cassette is named opsmaru_incus and holds both operation documents:
# the composite one (source opsmaru_incus) and the native one (source
# opsmaru_incus_native). tama_dex is a dev-only dependency, so this runs in
# the dev environment. The cassette is then imported into a fresh index,
# pinned to the SHA-256 just written, to prove both sources are searchable.
#
# Nothing is published here. The release workflow calls this only after the
# Hex release is live; run it locally to check a build.
#
# Usage: build-cassette.sh VERSION OUTPUT_DIR
set -euo pipefail

version="${1:?usage: build-cassette.sh VERSION OUTPUT_DIR}"
output_dir="${2:?usage: build-cassette.sh VERSION OUTPUT_DIR}"
name="opsmaru_incus-${version}.tama-cassette"

mkdir -p "${output_dir}"
rm -f "${output_dir}/${name}" "${output_dir}/${name}.sha256"

MIX_ENV=dev mix tama.dex.cassette \
  --name opsmaru_incus \
  --version "${version}" \
  --document Opsmaru.Incus.Operations.Composite.openapi \
  --document Opsmaru.Incus.Operations.Native.openapi \
  --output "${output_dir}/${name}"

# The .sha256 file names the asset alone, so `shasum -a 256 -c` works beside it.
(
  cd "${output_dir}"
  if command -v sha256sum >/dev/null; then
    sha256sum "${name}" > "${name}.sha256"
  else
    shasum -a 256 "${name}" > "${name}.sha256"
  fi
)

MIX_ENV=dev mix run --no-start scripts/verify-cassette.exs \
  "${output_dir}/${name}" "${output_dir}/${name}.sha256" "${version}"
