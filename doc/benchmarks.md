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

## Server suite

`--suite server` runs SELECT, INSERT and round trips against a real server given by `CLICKHOUSE_HOST` (with `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD`); INSERT tables are created in the database `clickhoused_bench`. Use a release build of the server, for example:

```sh
docker run -d --name clickhoused-bench268 -p 19268:9000 -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    --ulimit nofile=262144:262144 clickhouse/clickhouse-server:26.8
CLICKHOUSE_HOST=localhost:19268 dub run :bench -b release -- --suite server
CLICKHOUSE_HOST=localhost:19268 sh bench/server-reference.sh   # the same queries with ClickHouse's own client
```

The times include the server's work and the (local) network. `bench/server-reference.sh` measures the same SELECTs with `clickhouse-client --format Null --time` (the server's cost plus a fast C++ client that decodes the blocks) and `SELECT 1` round trips with `clickhouse benchmark`.

### Results (2026-11-01, clickhoused 0.6.0)

Server 26.8.36.3 in Docker on the same machine (load average below 1–4 during the runs); LDC 1.36, `-b release`; two rounds, min times. SELECTs generate their rows on the server (`numbers(N)`; the 4 columns are `number`, `toString(number)`, `number / 7` and a `DateTime64(3)`).

| case | rows | min ms | Mrows/s | clickhouse-client ms |
|---|---:|---:|---:|---:|
| select numbers, drained | 10M | 18.1–24.3 | 410–550 | 20–22 |
| select numbers, column read | 10M | 19.4–19.5 | ~515 | |
| select 4 columns, drained | 5M | 102–122 | 41–49 | 43–83 |
| select 4 columns, drained, LZ4 | 5M | 237–321 | 16–21 | 202–280 |
| select 4 columns, column read | 5M | 162–171 | 29–31 | |
| select 4 columns, `query!T` | 5M | 298–339 | 15–17 | |
| select 4 columns, per-cell getters | 5M | 219–229 | 22–23 | |
| insert into `Null`, blocks | 2M | 48–58 | 35–41 | |
| insert into `Null`, blocks, LZ4 | 2M | 213–224 | 9 | |
| insert into `Null`, `addRow` | 2M | 112–136 | 15–18 | |
| insert into `Null`, structs | 2M | 120–127 | 16–17 | |
| insert into `MergeTree`, blocks | 2M | 162–190 | 11–12 | |
| insert into `MergeTree`, `addRow` | 2M | 230–269 | 7–9 | |
| `SELECT 1` round trip | 1,000 | 1.3–1.6 s | (1.3–1.6 ms each) | 1.45–1.8 ms each |
| `ping` | 1,000 | 220–248 | (0.22–0.25 ms each) | |
| pool lock and release | 10,000 | 2.6–3.3 | (0.3 µs each) | |

Observations:
- Numbers come in as fast as with ClickHouse's own client. With strings in the result, clickhoused takes about 1.5–2 times as long as `clickhouse-client` (whose C++ decoder is faster on strings); with LZ4 both are dominated by compression and close.
- On a local connection compression only adds work, in both directions; it pays off on real networks.
- `SELECT 1` latency is the server's query overhead: `clickhouse benchmark` gets the same 1.5–1.8 ms per query. A `ping` takes about 0.25 ms.
- Each `SELECT 1` allocates about 24 KB in the client (mostly the profile-events block that comes with every query); not a latency issue, but a candidate for later.
- Not covered yet: TLS, and fiber mode (the benchmark subpackage does not depend on vibe-core).

## Performance changes

Each change is measured back to back against a build of the previous commit, on the same machine in the same session (min times; the machine is noisy, so the ranges come from several rounds).

### LZ4 (#40)

Inner loops rewritten as checked pointer code: fixed 8/16-byte copies where enough room is left, short repeat distances without byte-by-byte copies, matches extended 8 bytes at a time, output buffers not zero-filled.

| case | before MB/s | after MB/s | speed-up |
|---|---:|---:|---:|
| lz4/compress 1 MiB chunks | 317–450 | 678–734 | 1.6–2.1x |
| lz4/decompress 1 MiB chunks | 534–660 | 4,062–4,420 | 6.6–7.6x |
| frame/encode lz4 | 318–416 | 624–731 | 1.8–2.0x |
| frame/decode lz4 | 525–626 | 2,977–3,310 | 5.3–5.7x |
| decode-lz4/6 columns | 150–215 | 155–260 | 1.0–1.4x |
| query/drain lz4 | 189–222 | 233–412 | 1.2–2.1x |

Decompression is now in the range the LZ4 project quotes for its reference implementation. With compression on, the remaining cost of a SELECT is decoding the columns (strings first), not LZ4.

### Strings (#42)

String values are read into shared buffers (`StringArena`: 4 KB first, doubling to 64 KB; long values on their own) instead of one allocation each, and the slice array of a column is allocated at once for up to 1M rows. `StringColumn.data` stays a `string[]`. Two rounds, min times in ms (before: `main` with #40):

| case | before ms | after ms | speed-up | alloc B/row |
|---|---:|---:|---:|---:|
| decode/String(10 B) | 83.3–88.6 | 17.9–18.4 | 4.6–4.8x | 32 → 28 |
| decode/String(1 KB) | 23.7–23.9 | 9.7–9.8 | 2.4–2.5x | 1377 → 1106 |
| decode/Nullable(String) | 130.9–132.4 | 44.8–54.3 | 2.4–3.0x | 32 → 28 |
| decode/Array(String) avg 4 | 392.3–416.0 | 84.4–98.3 | 4.2–4.6x | 91 → 116 |
| decode/Map(String, UInt64) avg 4 | 388.4–390.3 | 89.2–93.7 | 4.1–4.4x | 101 → 124 |
| decode/Tuple(UInt64, String) | 95.7–96.1 | 18.8–21.7 | 4.4–5.1x | 40 → 36 |
| decode/Variant(String, UInt64) | 49.1–54.5 | 11.9–12.6 | 3.9–4.6x | 29 → 28 |
| decode/Dynamic 3 types | 33.2–35.3 | 9.0–9.7 | 3.4–3.9x | 25 → 24 |
| decode/JSON ~60 B | 8.3–8.7 | 1.9–2.0 | 4.4–4.5x | 81 → 83 |
| decode/wide 24 columns | 139.7–150.1 | 80.2–83.2 | 1.7–1.9x | 266 → 261 |
| decode/6 columns, 1000-row blocks | 39.7–41.4 | 20.5–22.7 | 1.8–2.0x | 87 → 98 |
| query/drain | 100.3–101.5 | 23.1–24.2 | 4.1–4.4x | 56 → 52 |
| query/drain lz4 | 111.8–129.6 | 43.4–55.4 | 2.3–2.6x | 114 → 110 |
| query/query!T structs | 255.1–277.8 | 173.7–175.5 | 1.5–1.6x | 56 → 52 |
| query/per-cell getters | 114.0–120.9 | 41.4–41.8 | 2.8–2.9x | 56 → 52 |

`LowCardinality(String)` is unchanged (its dictionary is small; the time goes into expanding it per row). The allocated bytes now are mostly the 16-byte slice per value; the ClickHouse-style layout (bytes plus offsets) would remove that, at the cost of an API change. A value kept alive keeps its shared buffer alive.

### Bool, UUID, NULL maps, Float64 (#44)

`Bool` values and NULL maps are read straight into the column (every non-zero byte becomes `true`) and written in one piece; `UUID` columns are read in one piece and converted in place (each 8-byte half reversed), and written in 64 KB chunks; fixed-width columns grow without first filling new elements with `T.init` (for `Float64`, an element-by-element `NaN` fill was the whole difference to `UInt64`). Two rounds, min times in ms (before: `main` with #42):

| case | before ms | after ms | speed-up |
|---|---:|---:|---:|
| decode/Bool | 22.34–33.27 | 0.06–0.08 | ~400x |
| decode/Nullable(Int64) | 23.26–34.62 | 0.31–0.35 | 75–100x |
| decode/UUID | 42.52–56.23 | 1.20–1.70 | 33–35x |
| decode/Float64 | 1.97–2.15 | 0.21–0.30 | 7–9x |
| decode/Nullable(String) | 49.36–62.12 | 22.16–32.27 | 1.9–2.2x |
| encode/Bool | 1.41–1.87 | 0.02–0.04 | 35–90x |
| encode/UUID | 15.71–21.16 | 1.59–2.27 | 9–10x |
| encode/Nullable(Int64) | 2.10–2.98 | 0.34–0.37 | 6–8x |

The other cases are unchanged within noise (checked with alternating runs for `Map` and `Array`). The allocation counter now reports a few columns higher (e.g. `Array(UInt32)` 12 → 40 B/row): arrays used to grow in place, which `GC.allocatedInCurrentThread` does not count, and are now allocated once at their full size, which it does.

### Column appends (#46)

The column append methods write into a spare buffer each column keeps (`appendFast`), instead of `data ~= value`, whose runtime call (a GC block lookup) dominated per-row inserts. Reserving room alone had cut the allocations but not the time. Two rounds plus alternating re-runs, min times in ms (before: `main` with #44):

| case | before ms | after ms | speed-up | alloc B/row |
|---|---:|---:|---:|---:|
| insert/addRow | 141.3–143.3 | 49.9–63.2 | 2.3–2.8x | 143 → 84 |
| insert/structs | 148.3–177.8 | 49.0–51.1 | 3.0–3.5x | 144 → 84 |
| decode/LowCardinality(String) 100 keys | 73.3–74.4 | 32.1–32.3 | ~2.3x | 9 → 41 |
| decode/wide 24 columns | 60.4–80.5 | 39.9–42.1 | 1.4–2.0x | 253 → 379 |

Inserting row by row now runs at about 20 million rows/s (whole blocks: about 50 million). Other cases are unchanged within noise; cases that looked slower in the first pass (`frame/decode lz4`, whose code did not change, `encode/LowCardinality`, `readValue`, `Map`, `Tuple`) came out equal or faster in alternating runs. Allocation figures for decoded LowCardinality columns rise because their values now grow in a doubling spare buffer, counted by the GC counter, where they used to be extended in place, which it doesn't count.

### Struct mapping and timezones (#48)

`query!T` reads each field whose column has exactly the matching type (`long` and `Int64`, `string` and `String`, `SysTime` and `DateTime64`/`DateTime`, ...) straight from the column array; other fields still go through `readValue`. `resolveTimeZone` remembers its last lookup per thread and checks the name by identity first, since a column passes the same string for every cell. Three alternating rounds, min times in ms (before: `main` with #46):

| case | before ms | after ms | speed-up |
|---|---:|---:|---:|
| query/query!T structs | 180.9–247.4 | 64.8–87.3 | 2.8–3.2x |
| cells/getSysTime DateTime64(3, Europe/Lisbon) (new case) | 21.7–26.8 | 13.1–13.6 | 1.7–2.0x |

`query!T` now runs at about 12–15 million rows/s (reading the same columns directly: about 40 million). Columns with a timezone other than UTC used to pay a hash lookup per cell; UTC columns were already fast.

### Float text (#50)

The shortest-digit search behind `getString` of `Float32`/`Float64` (Steele and White's free-format algorithm, #24) runs on a checked 128-bit integer type when its numbers fit (nearly every `Float32`, doubles from about 1e-20 to 1e35), and falls back to `BigInt` otherwise; digits go into a stack buffer. Same algorithm, same text: checked again against the server's `toString()` on the 765,536 values of #24 (no mismatches), and a unit test compares both paths on thousands of values. Three alternating rounds, 100,000 values, min times (the machine was under heavy load, load average 12–14, so the absolute times are high):

| case | before ms | after ms | speed-up | alloc B/row |
|---|---:|---:|---:|---:|
| cells/getString Float64 | 2,545–6,590 | 237–508 | 7–22x | 3,166 → 87 |

On the random bit patterns of the server check, where most values have extreme exponents and take the BigInt fallback, the whole check is about 1.35 times faster.
