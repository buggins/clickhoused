# Benchmarks

Benchmarks of the clickhoused client itself. They live in the `:bench` dub subpackage and are run locally; nothing runs in CI.

```sh
dub run :bench -b release                       # all cases
dub run :bench -b release -- --filter decode/   # cases whose name contains the text
dub run :bench -b release -- --rows 100000 --runs 10 --min-time 2 --csv results.csv
```

Each case is prepared once (not timed), run once to warm up, then measured at least `--runs` times (default 5) and until `--min-time` seconds of measured time have passed (default 1). The table shows the median and the minimum time of one run, throughput from the median, and the bytes allocated by the GC per row. On a noisy machine compare the **min** column: the median moves with background load.

## Offline suite

No server is involved:

- **decode/encode**: blocks are encoded once with clickhoused's own writer, then decoded from memory (`readBlock`) or encoded again (`writeBlock` into a buffer, which copies like a socket send). Inputs are split into blocks of 65,536 rows, about what the server sends; one column per block, except the wide and small-block cases.
- **lz4, frame, cityhash, decode-lz4/zstd**: compression of a realistic payload (blocks of 6 mixed columns) in 1 MiB chunks, compressed frames with their CityHash checksum, and blocks decoded through a compressed stream as `Connection` does with `compression` on. ZSTD cases appear only with `--override-config clickhoused/zstd`.
- **query, insert**: a real `Connection` whose transport replays scripted server packets (Hello, a header block, data blocks, EndOfStream), so the whole SELECT/INSERT path runs with no server. Rows are `(id UInt64, name String, value Float64, ts DateTime64(3, 'UTC'))`.
- **cells**: per-cell getters on decoded columns, the access path of ddbc.

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

### Composite types, compression and APIs (2026-11-01)

Same machine and commit as above, plus the step-2 cases (#38). The machine was under load from other processes (load average 5–8 on 6 vCPUs): of two full runs, the first was up to twice as slow as this second one. Compare results only within one session, back to back.

#### Composite and new types

| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| decode/LowCardinality(String) 100 keys | 1000000 | 1.0 | 68.61 | 62.00 | 14.6 | 15 | 8.4 | 15 |
| decode/Nullable(String) | 1000000 | 11.0 | 183.98 | 171.72 | 5.4 | 60 | 31.8 | 6 |
| decode/Array(UInt32) avg 8 | 1000000 | 40.0 | 3.92 | 2.27 | 255.1 | 10217 | 12.4 | 264 |
| decode/Array(String) avg 4 | 1000000 | 52.0 | 574.47 | 556.88 | 1.7 | 91 | 91.1 | 5 |
| decode/Map(String, UInt64) avg 4 | 1000000 | 84.0 | 482.74 | 464.79 | 2.1 | 174 | 98.5 | 5 |
| decode/Tuple(UInt64, String) | 1000000 | 19.0 | 151.38 | 134.32 | 6.6 | 126 | 40.2 | 7 |
| decode/Decimal(18, 4) | 1000000 | 8.0 | 0.39 | 0.33 | 2564.1 | 20583 | 8.1 | 1000 |
| decode/Int128 | 1000000 | 16.0 | 0.92 | 0.79 | 1087.0 | 17449 | 16.1 | 1000 |
| decode/IPv6 | 1000000 | 16.0 | 0.91 | 0.78 | 1098.9 | 17627 | 16.1 | 1000 |
| decode/Variant(String, UInt64) | 1000000 | 10.5 | 68.09 | 60.01 | 14.7 | 154 | 29.3 | 15 |
| decode/Dynamic 3 types | 1000000 | 10.0 | 53.08 | 43.84 | 18.8 | 188 | 25.3 | 19 |
| decode/JSON ~60 B | 100000 | 6.3 | 13.16 | 11.81 | 7.6 | 477 | 80.8 | 75 |
| encode/LowCardinality(String) 100 keys | 1000000 | 1.0 | 53.39 | 48.76 | 18.7 | 19 | 8.3 | 19 |
| encode/Nullable(String) | 1000000 | 11.0 | 23.03 | 20.73 | 43.4 | 478 | 0.1 | 44 |
| encode/Array(UInt32) avg 8 | 1000000 | 40.0 | 2.46 | 2.14 | 406.5 | 16294 | 0.1 | 392 |
| encode/Array(String) avg 4 | 1000000 | 52.0 | 95.57 | 85.72 | 10.5 | 544 | 0.1 | 11 |
| encode/Map(String, UInt64) avg 4 | 1000000 | 84.0 | 89.71 | 80.78 | 11.1 | 937 | 0.1 | 12 |
| encode/Tuple(UInt64, String) | 1000000 | 19.0 | 20.86 | 18.82 | 47.9 | 911 | 0.1 | 48 |
| encode/Decimal(18, 4) | 1000000 | 8.0 | 0.39 | 0.22 | 2564.1 | 20567 | 0.1 | 1000 |
| encode/Int128 | 1000000 | 16.0 | 0.88 | 0.61 | 1136.4 | 18188 | 0.1 | 1000 |
| encode/IPv6 | 1000000 | 16.0 | 0.68 | 0.59 | 1470.6 | 23495 | 0.1 | 1000 |
| encode/Variant(String, UInt64) | 1000000 | 10.5 | 13.33 | 11.37 | 75.0 | 788 | 0.1 | 75 |
| encode/Dynamic 3 types | 1000000 | 10.0 | 8.46 | 6.83 | 118.2 | 1183 | 1.1 | 110 |
| encode/JSON ~60 B | 100000 | 6.3 | 3.52 | 2.40 | 28.4 | 1785 | 0.7 | 285 |
| decode/wide 24 columns | 200000 | 29.6 | 200.67 | 194.69 | 0.997 | 148 | 265.5 | 6 |
| encode/wide 24 columns | 200000 | 29.6 | 65.42 | 58.46 | 3.1 | 453 | 33.7 | 16 |
| decode/6 columns, 1000-row blocks | 200000 | 7.6 | 69.82 | 59.60 | 2.9 | 110 | 87.4 | 15 |
| encode/6 columns, 1000-row blocks | 200000 | 7.6 | 27.46 | 17.96 | 7.3 | 279 | 21.8 | 41 |

#### Compression

| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| lz4/compress 1 MiB chunks | 1000000 | 37.0 | 167.14 | 165.48 | 6.0 | 221 | 37.3 | 6 |
| lz4/decompress 1 MiB chunks | 1000000 | 37.0 | 109.73 | 103.56 | 9.1 | 337 | 37.2 | 9 |
| cityhash128 1 MiB chunks | 1000000 | 37.0 | 4.31 | 2.28 | 232.0 | 8596 | 0.0 | 242 |
| frame/encode lz4 | 1000000 | 37.0 | 189.29 | 167.61 | 5.3 | 196 | 68.5 | 6 |
| frame/decode lz4 | 1000000 | 37.0 | 129.03 | 117.11 | 7.8 | 287 | 68.4 | 8 |
| decode-lz4/6 columns | 1000000 | 37.0 | 446.43 | 379.16 | 2.2 | 83 | 134.5 | 5 |

#### Query and insert paths (scripted connection, no server)

| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| query/drain | 1000000 | 35.0 | 152.64 | 137.17 | 6.6 | 229 | 56.3 | 7 |
| query/drain lz4 | 1000000 | 35.0 | 455.37 | 350.58 | 2.2 | 77 | 113.8 | 5 |
| query/columns | 1000000 | 35.0 | 159.49 | 150.95 | 6.3 | 219 | 56.3 | 7 |
| query/query!T structs | 1000000 | 35.0 | 351.07 | 346.94 | 2.8 | 100 | 56.3 | 5 |
| query/per-cell getters | 1000000 | 35.0 | 228.69 | 216.28 | 4.4 | 153 | 56.3 | 5 |
| insert/addRow | 1000000 | 35.0 | 216.81 | 203.21 | 4.6 | 161 | 144.6 | 5 |
| insert/structs | 1000000 | 35.0 | 228.06 | 203.77 | 4.4 | 153 | 144.2 | 5 |
| insert/blocks | 1000000 | 35.0 | 32.53 | 22.79 | 30.7 | 1076 | 0.0 | 31 |

#### Per-cell getters

| case | rows | wire MB | median ms | min ms | Mrows/s | MB/s | alloc B/row | runs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| cells/getLong UInt64 | 1000000 | 0.0 | 11.09 | 8.38 | 90.2 |  | 0.0 | 89 |
| cells/getVariant UInt64 | 1000000 | 0.0 | 47.46 | 39.29 | 21.1 |  | 0.0 | 20 |
| cells/readValue!long UInt64 | 1000000 | 0.0 | 84.71 | 64.37 | 11.8 |  | 0.0 | 12 |
| cells/getString String | 1000000 | 0.0 | 11.18 | 9.01 | 89.4 |  | 0.0 | 89 |
| cells/getString Float64 | 100000 | 0.0 | 3147.15 | 2764.85 | 0.032 |  | 3166.1 | 5 |
| cells/getSysTime DateTime64(3) | 1000000 | 0.0 | 25.84 | 20.04 | 38.7 |  | 0.0 | 38 |
| cells/getString DateTime64(3) | 100000 | 0.0 | 236.86 | 235.26 | 0.422 |  | 160.0 | 5 |
| cells/getString Decimal(18, 4) | 100000 | 0.0 | 22.09 | 19.59 | 4.5 |  | 32.0 | 43 |

ZSTD (a separate run, `--override-config clickhoused/zstd`): frame encode 225 MB/s, **frame decode 1,120 MB/s**, decode-zstd/6 columns 123 MB/s.

### Observations from step 2

- **LZ4 is the biggest single cost with compression on.** Our pure-D LZ4 decompresses at 300–340 MB/s and compresses at about 220 MB/s, while libzstd decodes frames at 1,100 MB/s (LZ4 is normally the faster of the two, at several GB/s). A compressed SELECT reads at a third of the uncompressed speed (query/drain lz4 vs query/drain). CityHash128 runs at about 8.6 GB/s and is not the problem.
- **Strings dominate**: every type made of strings (`Array(String)`, `Map(String, ...)`, `Nullable(String)`, `Tuple(..., String)`, `LowCardinality(String)`, `Variant`/`Dynamic` with strings) decodes at 1.7–15 million rows/s with one GC allocation per value. Fixed-width composites (`Array(UInt32)`, `Decimal`, `Int128`, `IPv6`) run at 10–20 GB/s.
- **Small blocks cost little extra** per row (6 columns in 1,000-row blocks: 2.9 Mrows/s against about 3–7 for the same columns in large blocks), so per-block type parsing is not urgent.
- **query!T struct mapping** halves SELECT throughput compared with reading columns (2.8 vs 6.3 Mrows/s); `readValue!long` costs about 60 ns per cell against 9 ns for `getLong`.
- **INSERT with addRow or structs** runs at about 4.5 million rows/s and allocates about 145 bytes per row, against 31 million rows/s for whole blocks.
- **Text of floats and dates is slow**: `getString` of a `Float64` costs about 30 µs and 3 KB per value (the exact shortest-decimal path through BigInt), of a `DateTime64` about 2.4 µs and 160 bytes.
