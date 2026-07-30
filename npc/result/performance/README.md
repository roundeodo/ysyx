# NPC Performance Results

Run `make perf-record` from `npc/` to append one row. The command records the
MicroBench PMU measurement window, not simulator startup or shutdown cycles.

The commit in a row identifies the tested source tree. Commit source changes
first, record the result second, and commit this table in a separate commit.
Raw simulator logs are kept under `result/performance/logs/` and are ignored by
Git.

Record a result with an explicitly measured synthesis frequency:

```sh
make perf-record \
  PERF_DESCRIPTION="baseline before cache" \
  PERF_FREQUENCY_MHZ=296.552
```

Alternatively, extract the limiting max-path frequency from a specific STA
report:

```sh
make perf-record \
  PERF_DESCRIPTION="baseline before cache" \
  PERF_STA_REPORT=result/<design>/<design>.rpt
```

`PERF_SCALE` defaults to `train`. A `PERF_SCALE=test` row is useful for local
debugging, but it is not interchangeable with a formal `train` result.

| Date (UTC) | NPC commit | AM-kernels commit | Scale | Description | Simulation cycles | Retired instructions | IPC | Synthesis frequency (MHz) |
| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: |
<!-- PERFORMANCE_RESULTS:INSERT_BEFORE -->
