#!/bin/zsh
# semantic-release prepare: signed + notarized Float for the computed version → dist/Float-<version>.zip
set -euo pipefail
cd "${0:A:h}/.."
version=${1:?usage: release-prepare.sh <version>}
# CFBundleVersion drives Sparkle's ordering, so it must only ever increase (CI: workflow run number)
build=${FLOAT_BUILD_NUMBER:?FLOAT_BUILD_NUMBER required}
[[ $build =~ ^[1-9][0-9]*$ ]] || { echo "✗ FLOAT_BUILD_NUMBER must be a positive integer: $build" >&2; exit 1; }
: "${NOTARY_KEY_PATH:?NOTARY_KEY_PATH required}" "${NOTARY_KEY_ID:?}" "${NOTARY_KEY_ISSUER:?}"
VERSION=$version BUILD=$build NOTARIZE=1 ./build.sh
