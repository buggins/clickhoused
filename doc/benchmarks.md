# Benchmarks

Benchmarks of the clickhoused client itself. They live in the `:bench` dub subpackage and are run locally; nothing runs in CI.

```sh
dub run :bench -b release                       # all cases
dub run :bench -b release -- --filter decode/   # cases whose name contains the text
dub run :bench -b release -- --rows 100000 --runs 10 --min-time 2 --csv results.csv
```

Each case is prepared once (not timed), run once to warm up, then measured at least `--runs` times (default 5) and until `--min-time` seconds of measured time have passed (default 1). The table shows the median and the minimum time of one run, throughput from the median, and the bytes allocated by the GC per row. On a noisy machine compare the **min** column: the median moves with background load.

## Offline suite

No server: blocks are encoded once with clickhoused's own writer, then decoded from memory (`readBlock`) or encoded again (`writeBlock` into a buffer, which copies like a socket send). Inputs are split into blocks of 65,536 rows, about what the server sends; one column per block.

### Baseline (2026-11-01)

- Commit `35f58cc` (0.5.0), LDC 1.36.0, `dub -b release`.
- AMD Ryzen AI 7 350, 6 vCPUs, WSL2 (kernel 6.6), with a Debug ClickHouse server and Docker containers idle in the background, so the medians are noisy.

| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| decode/UInt64 | 1000000 | 8.0 | 0.98 | 0.57 | 1025.4 | 8204 | 8.1 | 549 |
| decode/Int32 | 1000000 | 4.0 | 0.38 | 0.29 | 2626.1 | 10505 | 4.1 | 1000 |
| decode/Float64 | 1000000 | 8.0 | 11.91 | 4.33 | 84.0 | 672 | 8.1 | 82 |
| decode/Bool | 1000000 | 1.0 | 167.93 | 119.86 | 6.0 | 6 | 1.3 | 6 |
| decode/String(10 B) | 1000000 | 11.0 | 534.03 | 293.97 | 1.9 | 21 | 32.1 | 5 |
| decode/String(1 KB) | 100000 | 102.6 | 94.70 | 54.66 | 1.1 | 1083 | 1376.8 | 9 |
| decode/FixedString(16) | 1000000 | 16.0 | 1.95 | 1.33 | 514.1 | 8225 | 16.1 | 342 |
| decode/Nullable(Int64) | 1000000 | 9.0 | 90.57 | 66.09 | 11.0 | 99 | 9.4 | 10 |
| decode/Date | 1000000 | 2.0 | 0.28 | 0.17 | 3602.3 | 7206 | 2.1 | 1000 |
| decode/DateTime | 1000000 | 4.0 | 0.46 | 0.31 | 2158.0 | 8633 | 4.1 | 803 |
| decode/DateTime64(3) | 1000000 | 8.0 | 0.88 | 0.58 | 1138.4 | 9108 | 8.1 | 500 |
| decode/UUID | 1000000 | 16.0 | 199.53 | 152.86 | 5.0 | 80 | 16.1 | 6 |
| decode/Enum8 | 1000000 | 1.0 | 0.24 | 0.14 | 4223.0 | 4226 | 1.2 | 1000 |
| encode/UInt64 | 1000000 | 8.0 | 0.56 | 0.35 | 1788.6 | 14309 | 0.1 | 1000 |
| encode/Int32 | 1000000 | 4.0 | 0.25 | 0.17 | 3998.4 | 15995 | 0.1 | 1000 |
| encode/Float64 | 1000000 | 8.0 | 0.64 | 0.36 | 1564.5 | 12516 | 0.1 | 641 |
| encode/Bool | 1000000 | 1.0 | 13.26 | 2.48 | 75.4 | 75 | 0.1 | 76 |
| encode/String(10 B) | 1000000 | 11.0 | 78.73 | 42.05 | 12.7 | 140 | 0.1 | 13 |
| encode/String(1 KB) | 100000 | 102.6 | 55.93 | 25.54 | 1.8 | 1835 | 0.7 | 18 |
| encode/FixedString(16) | 1000000 | 16.0 | 1.46 | 0.86 | 683.3 | 10933 | 0.1 | 432 |
| encode/Nullable(Int64) | 1000000 | 9.0 | 7.09 | 3.21 | 141.0 | 1269 | 0.1 | 112 |
| encode/Date | 1000000 | 2.0 | 0.12 | 0.09 | 8000.0 | 16003 | 0.1 | 1000 |
| encode/DateTime | 1000000 | 4.0 | 0.32 | 0.17 | 3167.6 | 12671 | 0.1 | 1000 |
| encode/DateTime64(3) | 1000000 | 8.0 | 0.89 | 0.38 | 1125.0 | 9000 | 0.1 | 575 |
| encode/UUID | 1000000 | 16.0 | 80.36 | 63.13 | 12.4 | 199 | 0.1 | 13 |
| encode/Enum8 | 1000000 | 1.0 | 0.07 | 0.05 | 14684.3 | 14696 | 0.1 | 1000 |

### First observations

To confirm with profiling in the performance pass (PLAN step 5):

- Fixed-width numbers and dates (`UInt64`, `Int32`, `Date`, `DateTime`, `DateTime64`, `Enum8`, `FixedString`) decode and encode at 8–16 GB/s: one copy per column, close to memory bandwidth.
- `Float64` decodes 7–10 times slower than `UInt64`, although both are fixed-width columns read in bulk. Worth a look.
- `Bool` decodes at 6–14 million rows/s, about 300 times slower than `Enum8` (also one byte per row): it is not read in bulk.
- `UUID` decodes at about 5 and encodes at about 12 million rows/s: values are converted one by one.
- `Nullable(Int64)` decodes at about 11 million rows/s: the NULL map is built one byte at a time.
- `String` decodes at 2–3 million short values per second, with one GC allocation (32 bytes per 10-byte value) per row; encoding is about 5 times faster.
