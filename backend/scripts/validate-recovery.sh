#!/usr/bin/env bash
# Isolated, local protocol verification. Does not deploy or access any VPS.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
for command in initdb pg_ctl createdb psql redis-server go xcodebuild openssl curl lsof; do
    command -v "$command" >/dev/null || { printf 'Missing tool: %s\n' "$command" >&2; exit 1; }
done
for port in 55439 55440 55441; do
    if lsof -n -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        printf 'Validation port unavailable: %s\n' "$port" >&2; exit 1
    fi
done
: "${LUMA_TEST_SIMULATOR:?Set LUMA_TEST_SIMULATOR to an available iOS simulator UUID}"
TEST_DIR=$(mktemp -d /tmp/luma-recovery-validation.XXXXXX)
cleanup() {
    if [[ -n ${BACKEND_PID:-} ]]; then kill "$BACKEND_PID" 2>/dev/null || true; wait "$BACKEND_PID" 2>/dev/null || true; fi
    if [[ -f "$TEST_DIR/redis.pid" ]]; then kill "$(cat "$TEST_DIR/redis.pid")" 2>/dev/null || true; fi
    pg_ctl -D "$TEST_DIR/pg" -m immediate stop >/dev/null 2>&1 || true
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
initdb -D "$TEST_DIR/pg" -A trust --no-locale >/dev/null
pg_ctl -D "$TEST_DIR/pg" -l "$TEST_DIR/pg.log" -o "-h 127.0.0.1 -p 55439 -k $TEST_DIR" start >/dev/null
createdb -h 127.0.0.1 -p 55439 recovery_tests
psql -h 127.0.0.1 -p 55439 -d recovery_tests -c 'CREATE TABLE schema_migrations(version integer PRIMARY KEY)' >/dev/null
for file in "$ROOT"/backend/migrations/*.sql; do
    psql -h 127.0.0.1 -p 55439 -d recovery_tests -v ON_ERROR_STOP=1 -f "$file" >/dev/null
    version=$(basename "$file" | cut -d_ -f1)
    psql -h 127.0.0.1 -p 55439 -d recovery_tests -c "INSERT INTO schema_migrations VALUES ($((10#$version)))" >/dev/null
done
redis-server --bind 127.0.0.1 --port 55440 --save "" --appendonly no --daemonize yes --pidfile "$TEST_DIR/redis.pid" --logfile "$TEST_DIR/redis.log"
export LUMA_DEVICE_TEST_DSN="postgres://$(id -un)@127.0.0.1:55439/recovery_tests?sslmode=disable"
export LUMA_FILE_TEST_DSN="$LUMA_DEVICE_TEST_DSN" LUMA_USERID_INDEX_TEST_DSN="$LUMA_DEVICE_TEST_DSN"
export LUMA_REDIS_TEST_URL='redis://127.0.0.1:55440/0'
cd "$ROOT/backend"
go build ./...
go vet ./...
go test -count=1 -v ./...
# Existing integration fixtures contain fixed names, so race validation needs its own database.
createdb -h 127.0.0.1 -p 55439 recovery_race
psql -h 127.0.0.1 -p 55439 -d recovery_race -c 'CREATE TABLE schema_migrations(version integer PRIMARY KEY)' >/dev/null
for file in "$ROOT"/backend/migrations/*.sql; do
    psql -h 127.0.0.1 -p 55439 -d recovery_race -v ON_ERROR_STOP=1 -f "$file" >/dev/null
    version=$(basename "$file" | cut -d_ -f1)
    psql -h 127.0.0.1 -p 55439 -d recovery_race -c "INSERT INTO schema_migrations VALUES ($((10#$version)))" >/dev/null
done
export LUMA_DEVICE_TEST_DSN="postgres://$(id -un)@127.0.0.1:55439/recovery_race?sslmode=disable"
export LUMA_FILE_TEST_DSN="$LUMA_DEVICE_TEST_DSN" LUMA_USERID_INDEX_TEST_DSN="$LUMA_DEVICE_TEST_DSN"
go test -race -count=1 -v ./...
createdb -h 127.0.0.1 -p 55439 recovery_http
export DATABASE_URL="postgres://$(id -un)@127.0.0.1:55439/recovery_http?sslmode=disable"
export REDIS_URL="$LUMA_REDIS_TEST_URL"
export LUMA_USERID_HMAC_SECRET=$(openssl rand -hex 32)
export LUMA_ADDR='127.0.0.1:55441' LUMA_ALLOW_INSECURE_LOCAL=true LOCAL_STORAGE_DIR="$TEST_DIR/storage"
go build -o "$TEST_DIR/backend" ./cmd/luma
"$TEST_DIR/backend" > "$TEST_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
ready=false
for _ in $(seq 1 50); do
    kill -0 "$BACKEND_PID" 2>/dev/null || { printf 'Isolated backend exited\n' >&2; exit 1; }
    if curl -fsS http://127.0.0.1:55441/ready >/dev/null 2>&1; then ready=true; break; fi
    sleep 0.2
done
[[ $ready == true ]] || { printf 'Isolated backend failed readiness\n' >&2; exit 1; }
cd "$ROOT"
xcodebuild build -project Luma.xcodeproj -scheme Luma -configuration Debug -destination "platform=iOS Simulator,id=$LUMA_TEST_SIMULATOR" -derivedDataPath "${LUMA_TEST_DERIVED_DATA:-/tmp/luma-recovery-derived}"
xcodebuild test -project Luma.xcodeproj -scheme Luma -destination "platform=iOS Simulator,id=$LUMA_TEST_SIMULATOR" -derivedDataPath "${LUMA_TEST_DERIVED_DATA:-/tmp/luma-recovery-derived}"
xcodebuild build -project Luma.xcodeproj -scheme Luma -configuration Release -destination 'generic/platform=iOS Simulator' -derivedDataPath "${LUMA_TEST_DERIVED_DATA:-/tmp/luma-recovery-derived}" CODE_SIGNING_ALLOWED=NO
