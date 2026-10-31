#!/bin/sh
# Starts a ClickHouse container with TLS for the integration tests, using the
# test certificates from source/clickhoused/io/testdata.
#
#   sh integration-tests/tls/start-server.sh [image-tag] [host-port] [container-name]
#
# Then run the tests with:
#   CLICKHOUSE_HOST=localhost:19440 CLICKHOUSE_SECURE=1 \
#   CLICKHOUSE_TLS_CA=$PWD/source/clickhoused/io/testdata/ca.pem \
#   CLICKHOUSE_TLS_DIR=$PWD/source/clickhoused/io/testdata CLICKHOUSE_TLS_CERT_USER=cert_user \
#   dub run :integration-tests-phobos
set -eu
tag=${1:-latest}
port=${2:-19440}
name=${3:-clickhoused-ch-tls}
here=$(cd "$(dirname "$0")" && pwd)
certs=$(cd "$here/../../source/clickhoused/io/testdata" && pwd)

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" -p "$port:9440" -e CLICKHOUSE_SKIP_USER_SETUP=1 \
    -v "$here/tls.xml:/etc/clickhouse-server/config.d/tls.xml:ro" \
    -v "$here/cert-user.xml:/etc/clickhouse-server/users.d/cert-user.xml:ro" \
    -v "$certs:/etc/clickhouse-server/certs:ro" \
    "clickhouse/clickhouse-server:$tag" >/dev/null

# Wait until the server accepts queries
i=0
until docker exec "$name" clickhouse-client -q "SELECT 1" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        docker logs "$name" | tail -20
        echo "ClickHouse did not start" >&2
        exit 1
    fi
    sleep 1
done
echo "ClickHouse $tag with TLS is listening on localhost:$port"
