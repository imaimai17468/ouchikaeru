#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

swift format lint \
    --configuration .swift-format \
    --parallel \
    --recursive \
    --strict \
    Sources Shared iPhone Widget Watch Tests UITests

if ! command -v swiftlint >/dev/null 2>&1; then
    print -u2 "SwiftLint is required. Install it with: brew install swiftlint"
    exit 1
fi

swiftlint lint --strict --quiet --cache-path /tmp/ouchikaeru-swiftlint-cache
export CLANG_MODULE_CACHE_PATH=/tmp/ouchikaeru-clang-module-cache
export SWIFTPM_MODULECACHE_OVERRIDE=/tmp/ouchikaeru-swiftpm-module-cache
swift_test_arguments=(
    --cache-path /tmp/ouchikaeru-swiftpm-cache
    --scratch-path /tmp/ouchikaeru-swiftpm-build
)
if [[ -n "${CODEX_SANDBOX:-}" ]]; then
    # SwiftPM cannot start its nested sandbox inside the agent's existing sandbox.
    swift_test_arguments+=(--disable-sandbox)
fi
swift test "${swift_test_arguments[@]}"
