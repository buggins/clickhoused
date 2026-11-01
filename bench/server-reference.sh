#!/bin/sh
# Reference numbers for the server suite of the clickhoused benchmarks: the same queries with
# ClickHouse's own client (the server's cost plus a fast C++ client), on the server given by
# CLICKHOUSE_HOST (host:port, default localhost:9000). Needs the `clickhouse` binary.
#
#   sh bench/server-reference.sh
set -eu
HOSTPORT=${CLICKHOUSE_HOST:-localhost:9000}
HOST=${HOSTPORT%:*}
PORT=${HOSTPORT##*:}
[ "$PORT" = "$HOSTPORT" ] && PORT=9000

NUMBERS="SELECT number FROM numbers(10000000)"
MIXED="SELECT number AS id, toString(number) AS name, number / 7 AS value, toDateTime64(1600000000 + number, 3, 'UTC') AS ts FROM numbers(5000000)"

# Query time as clickhouse-client reports it (--time), five runs, with and without compression
for compression in 0 1; do
    for name in NUMBERS MIXED; do
        eval "query=\$$name"
        times=""
        for _ in 1 2 3 4 5; do
            times="$times $(clickhouse client --host "$HOST" --port "$PORT" --compression $compression \
                --format Null --time -q "$query" 2>&1 | tail -1)"
        done
        echo "clickhouse-client $name compression=$compression: $times s"
    done
done

# Round trips: SELECT 1 from one connection
clickhouse benchmark --host "$HOST" --port "$PORT" -c 1 -i 2000 --query "SELECT 1" 2>&1 | grep 'queries: 2000'
