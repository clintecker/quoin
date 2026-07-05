# Editing Responsiveness Baselines

Quoin's CI performance tests are smoke tests with broad timing headroom for
shared macOS runners. Use the local release benchmark for edit-loop work:

```sh
scripts/benchmark-editing-responsiveness.sh
scripts/benchmark-editing-responsiveness.sh /path/to/large.md
QUOIN_BENCH_ENFORCE=1 scripts/benchmark-editing-responsiveness.sh /path/to/large.md
```

The script builds a temporary release-mode harness against this checkout, then
measures:

- initial full parse
- cold render
- byte-precise middle insert
- full parse after that insert
- warm-cache render after that insert
- old/new rendered string diff scan

Current local baseline on `/Users/clint/Downloads/moby_dick.md`:

| Metric | Time |
| --- | ---: |
| Bytes | 1,204,081 |
| Lines | 5,402 |
| Parsed blocks | 2,701 |
| Headings | 137 |
| `parse.initial` | 355.61 ms |
| `render.cold` | 100.44 ms |
| `source.applyEdit` | 0.88 ms |
| `parse.middleInsert` | 337.90 ms |
| `render.middleInsert.warmCache` | 80.12 ms |
| `render.fullStringDiffScan` | 12.14 ms |

Interpretation:

- Full-document parse is the dominant per-edit cost on book-sized prose.
- Warm render is improved by fragment caching, but still above a frame budget.
- The full-string diff scan is smaller than parse/render but still visible.

`QUOIN_BENCH_ENFORCE=1` applies local release thresholds with enough headroom to
catch major regressions without pretending to be a CI-stable benchmark. Keep the
thresholds looser than the intended interaction budget; they are regression
guards, not the final target.
