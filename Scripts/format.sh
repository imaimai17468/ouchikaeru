#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

swift format format \
    --configuration .swift-format \
    --in-place \
    --parallel \
    --recursive \
    Sources Shared iPhone Widget Watch Tests UITests
