#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${TEST_DIR}/test-installer.sh" "$@"
if [[ "${1:-all}" == "all" ]]; then
  bash "${TEST_DIR}/test-static-check.sh"
  bash "${TEST_DIR}/test-ci-workflow.sh"
fi
