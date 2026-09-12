#!/bin/sh
# Every test. Each *_test.lua runs under `nvim -l`; the OpenCode writer's test
# runs under bun when bun is on PATH. Exit code: the first failure.
set -e
cd "$(dirname "$0")/.."
for t in tests/*_test.lua; do
  echo "== $t"
  nvim -l "$t"
done
if command -v bun >/dev/null 2>&1; then
  echo "== tests/opencode_test.ts"
  bun run tests/opencode_test.ts
else
  echo "== tests/opencode_test.ts: skipped, bun not on PATH"
fi
