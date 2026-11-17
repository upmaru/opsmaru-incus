#!/usr/bin/env bash
# Waits until Hex serves one opsmaru_incus release and its docs.
#
# Hex stages releases published with an API key until an owner approves them.
# This polls hex-release-state.sh, shows the approval page while the release
# is staged, and returns once the package and docs are both live. It uploads
# nothing.
#
# It stops with an error when:
#
# - the wait runs out (HEX_WAIT_TIMEOUT seconds, default 3600);
# - the package is missing, so its staged upload was rejected or expired;
# - the package is live but its docs stay missing for HEX_DOCS_GRACE seconds
#   (default 300);
# - Hex cannot be read HEX_WAIT_ERRORS times in a row (default 5). A request
#   that gets no answer within 30 seconds counts as one failed read.
#
# Rerunning the workflow run after any of these is safe: it uploads only what
# is missing and waits again.
#
# Usage: wait-for-hex-release.sh VERSION
set -euo pipefail

version="${1:?usage: wait-for-hex-release.sh VERSION}"
timeout="${HEX_WAIT_TIMEOUT:-3600}"
interval="${HEX_WAIT_INTERVAL:-30}"
docs_grace="${HEX_DOCS_GRACE:-300}"
max_errors="${HEX_WAIT_ERRORS:-5}"
state_script="$(dirname "${BASH_SOURCE[0]}")/hex-release-state.sh"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

fail() {
  echo "::error::$1"
  echo "$1" >> "${summary}"
  exit 1
}

started="${SECONDS}"
errors=0
last=""
announced=""
docs_missing_since=""

while true; do
  if state="$("${state_script}" "${version}")"; then
    errors=0
  else
    errors=$((errors + 1))

    if ((errors >= max_errors)); then
      fail "Hex could not be read ${errors} times in a row. Rerun this workflow run once Hex answers."
    fi

    state=""
  fi

  if [[ -n "${state}" ]]; then
    package="$(sed -n 's/^package=//p' <<< "${state}")"
    docs="$(sed -n 's/^docs=//p' <<< "${state}")"
    approval_url="$(sed -n 's/^approval_url=//p' <<< "${state}")"

    if [[ "package ${package}, docs ${docs}" != "${last}" ]]; then
      last="package ${package}, docs ${docs}"
      echo "opsmaru_incus ${version} on Hex: ${last}"
    fi

    if [[ "${package}" == "live" && "${docs}" == "live" ]]; then
      exit 0
    fi

    if [[ "${package}" == "missing" ]]; then
      fail "opsmaru_incus ${version} is no longer staged on Hex: the upload was rejected or expired. Rerun this workflow run to upload it again."
    fi

    if [[ "${package}" == "staged" || "${docs}" == "staged" ]] && [[ -z "${announced}" ]]; then
      message="opsmaru_incus ${version} is staged on Hex. Approve it at ${approval_url}; this run continues once Hex serves it."
      echo "::notice::${message}"
      echo "${message}" >> "${summary}"
      announced="yes"
    fi

    # Docs staged with the package are not reported until the package is
    # live, so missing docs only count from then.
    if [[ "${package}" == "live" && "${docs}" == "missing" ]]; then
      docs_missing_since="${docs_missing_since:-${SECONDS}}"

      if ((SECONDS - docs_missing_since >= docs_grace)); then
        fail "opsmaru_incus ${version} is live on Hex without docs. Rerun this workflow run to upload them."
      fi
    else
      docs_missing_since=""
    fi
  fi

  if ((SECONDS - started >= timeout)); then
    fail "opsmaru_incus ${version} was not live on Hex after ${timeout} seconds (${last:-state unknown}). Approve it at ${approval_url:-https://hex.pm/dashboard}, then rerun this workflow run."
  fi

  sleep "${interval}"
done
