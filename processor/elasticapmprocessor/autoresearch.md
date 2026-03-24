# Autoresearch: elasticapmprocessor ConsumeTraces

## Objective
Optimize `EnrichTraces` — the hot-path span enrichment loop in `processor/elasticapmprocessor`.
Workload: ECS mode, 10 resources × 5 scopes × 100 HTTP server spans = 5000 spans/batch.
Spans are SpanKindServer, so all are treated as Elastic transactions → `enrichTransaction` runs for every span.

## Metrics
- **Primary**: ns_per_span (ns, lower is better)
- **Secondary**: allocs_per_op

## How to Run
`./autoresearch.sh` — outputs `METRIC name=number` lines.

## Files in Scope
- `processor/elasticapmprocessor/internal/enrichments/span.go` — Main enrichment logic. `EnrichSpan`, `enrichTransaction`, `setEventOutcome`, `setInferredSpans`, `extractURLHost`.
- `processor/elasticapmprocessor/internal/enrichments/attribute/attribute.go` — `PutStr/PutInt/PutBool/PutDouble` wrappers that check key existence before inserting.
- `processor/elasticapmprocessor/processor_bench_test.go` — Benchmark harness.

## Off Limits
- Tests must pass (run `go test ./...` before committing)
- No new external dependencies
- No semantic changes — enrichment output must remain identical

## Constraints
- Keep test compatibility: `go test ./...` must pass
- Benchmark: `BenchmarkProcessorConsumeTraces_ECS/r10_s5_sp100`

## What's Been Tried

### Run 1: Baseline — 475 ns/span (KEEP)
Original code with `url.Parse` for every HTTP span's url.full attribute. Baseline.

### Run 2: extractURLHost — 364 ns/span (KEEP, -23%)
Replaced `url.Parse` with fast single-pass string scanner `extractURLHost()` that avoids the full parser. Falls back to `url.Parse` only for URLs with userinfo (`@`).
Saved: 22% of CPU that was in `url.Parse`.

### Run 3: Lazy childIDs slice — 320 ns/span (KEEP, -12%)
In `setInferredSpans`, `pcommon.NewSlice()` was called for every span unconditionally (even with no links). Added fast-path early return when `spanLinks.Len() == 0`, and moved `pcommon.NewSlice()` inside the RemoveIf callback to allocate only when needed.
Saved: 98.5% allocation reduction (from 10150 to 148 allocs/op).

## Remaining Hotspots (after Run 3)
From CPU profile:
1. `Map.Get` = 29.55% flat — double-scan in `attribute.PutStr` (Get+Put per write, instead of 1 Put)
2. `Map.Range` = 5.50% flat, 25.26% cumulative — attribute scan in Enrich() loop
3. `Enrich.func1` = 9.79% flat — Range callback switch statement
4. `setEventOutcome` = 11.17% cumulative — 5 linear scans: initial check + 2×(Get+Put)
5. `extractURLHost` = 7.22% cumulative — still 7% despite optimization; `strings.ToLower` every call
6. `runtime.madvise` = 20.96% — OS memory management, partially from TracesSink growing

## Key Insights
1. **Root cause of allocs**: pdata `PutBool`/`PutStr` always call `NewAnyValue*()` — eliminated by `pdata.useProtoPooling` feature gate (Alpha).
2. **Double-scan pattern**: `attribute.PutStr(attrs, key, val)` = `attrs.Get(key)` + `attrs.PutStr(key, val)`. pdata's own `PutStr` does 1 scan (find slot + insert). The wrapper adds a redundant pre-check scan. For spans without pre-set elastic attributes (OTLP path), ALL pre-checks miss = wasteful.
3. **`setEventOutcome` is hot**: 3 Gets for EventOutcome alone (initial check + wrapper pre-check + pdata's own Get inside PutStr). Can reduce to 2 by reusing the initial check result.
4. **Intake ECS path**: Intake receiver pre-sets many elastic attributes. The `Get` pre-check is necessary for correctness on this path (don't overwrite intake-supplied values). Cannot remove globally.

## Next Ideas
1. **[TRIED]** extractURLHost: fast URL parsing — saves 22%
2. **[TRIED]** Lazy childIDs: avoid pcommon.NewSlice() — saves 12%
3. **[NEXT]** setEventOutcome: reuse initial Get result, skip double-check on hot path — expected ~5%
4. Single-pass extractURLHost combining IndexAny + IndexByte into one loop
5. strings.ToLower in extractURLHost: only call if string has uppercase chars (for ASCII, check first char range)
6. Batch the "absent" case: detect if no elastic attrs present and skip all Get pre-checks
