#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Quick syntax check
go build ./... 2>&1
if [ $? -ne 0 ]; then
  echo "Build failed"
  exit 1
fi

# Run benchmark — ECS mode with r10_s5_sp100 (5000 spans/batch, the MOTel production shape)
OUTPUT=$(go test -bench=BenchmarkProcessorConsumeTraces_ECS/r10_s5_sp100 \
  -run='^$' \
  -benchtime=3s \
  -count=1 \
  -benchmem \
  2>&1)

echo "$OUTPUT"

# Extract ns/span custom metric
NS_PER_SPAN=$(echo "$OUTPUT" | grep -oE '[0-9]+\.[0-9]+ ns/span' | head -1 | grep -oE '[0-9]+\.[0-9]+')
ALLOCS=$(echo "$OUTPUT" | grep -oE '[0-9]+ allocs/op' | head -1 | grep -oE '^[0-9]+')

if [ -z "$NS_PER_SPAN" ]; then
  echo "Failed to extract ns/span metric"
  exit 1
fi

echo "METRIC ns_per_span=$NS_PER_SPAN"
echo "METRIC allocs_per_op=${ALLOCS:-0}"
