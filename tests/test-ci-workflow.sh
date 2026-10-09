#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="${TEST_DIR}/../.github/workflows/check.yml"

grep -Fq 'apt-get install -y --no-install-recommends bash coreutils grep sed git ca-certificates' "${WORKFLOW}"
grep -Fq 'dnf install -y bash grep sed git ca-certificates' "${WORKFLOW}"
if grep -Fq 'dnf install -y bash coreutils' "${WORKFLOW}"; then
  printf 'Rocky Linux 容器不应用 coreutils 替换预装的 coreutils-single\n' >&2
  exit 1
fi

grep -Fq 'shellcheck install.sh tests/run.sh tests/static-check.sh tests/test-static-check.sh tests/test-ci-workflow.sh' "${WORKFLOW}"
grep -Fq 'shellcheck -e SC2317 tests/test-installer.sh' "${WORKFLOW}"

printf 'CI workflow checks passed\n'
