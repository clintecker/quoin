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
- parser strategy for that middle insert
- incremental parse-after-edit when the edit qualifies for a safe fast path
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
| Edit block bytes | 170 |
| `parse.initial` | 345.94 ms |
| `render.cold` | 96.07 ms |
| `source.applyEdit` | 0.88 ms |
| `parseAfterEdit.middleInsert` | 8.83 ms |
| `parseAfterEdit.strategy` | `plainParagraphFastPath` |
| `parse.middleInsert` | 328.31 ms |
| `render.middleInsert.warmCache` | 75.73 ms |
| `render.fullStringDiffScan` | 12.06 ms |

Interpretation:

- Full-document parse is the dominant per-edit cost on book-sized prose when
  the edit is not eligible for the incremental fast path.
- Plain active-paragraph edits can avoid that full parse and stay near a
  single-frame budget on this fixture.
- Warm render is improved by fragment caching, but still above a frame budget.
- The full-string diff scan is smaller than parse/render but still visible.

`QUOIN_BENCH_ENFORCE=1` applies local release thresholds with enough headroom to
catch major regressions without pretending to be a CI-stable benchmark. Keep the
thresholds looser than the intended interaction budget; they are regression
guards, not the final target.
