#!/usr/bin/env bash
# Exercise the wrapper without external object storage: CLI/version passthrough,
# asset-only starter build, missing-bucket guard, unprivileged runtime, public
# health/Worker routes, volume writes, and graceful SIGTERM handling.
set -euo pipefail

IMAGE="${1:-railway-celld:test}"
NAME="celld-smoke-$$"
VOLUME="${NAME}-state"
PORT="${SMOKE_PORT:-18080}"
LOG="$(mktemp)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
  rm -f "$LOG"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  docker logs "$NAME" 2>&1 | tail -80 >&2 || true
  exit 1
}
pass() { echo "  ok: $*"; }

echo "==> upstream CLI"
expected="$(sed -n 's/^ARG CELLD_VERSION=//p' "$ROOT/Dockerfile")"
version="$(docker run --rm "$IMAGE" --version)"
[[ "$version" == *"$expected"* ]] || fail "expected celld $expected, got: $version"
pass "$version"
docker run --rm "$IMAGE" --help | grep -q 'CELLD_INTERNAL_ADDR' \
  || fail "celld help does not expose the split internal listener"
pass "help/version passthrough"

echo "==> bundled starter"
docker run --rm "$IMAGE" deploy /opt/celld/starter --dry-run \
  | grep -q 'Current Version ID:' \
  || fail "asset-only starter did not build"
pass "asset-only starter builds without esbuild or a bucket"

echo "==> missing-bucket guard"
set +e
docker run --rm "$IMAGE" >"$LOG" 2>&1
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "empty runtime config exited $rc, expected 1"
grep -q 'CELLD_BUCKET is missing or empty' "$LOG" \
  || fail "missing CELLD_BUCKET error was not actionable"
pass "empty runtime config fails closed"

echo "==> runtime"
docker volume create "$VOLUME" >/dev/null
docker run -d --name "$NAME" \
  --mount "type=volume,src=$VOLUME,dst=/var/lib/celld" \
  --mount "type=bind,src=$ROOT/test/fixtures/worker.js,dst=/tmp/worker.js,readonly" \
  -e CELLD_TEST_SCRIPT_PATH=/tmp/worker.js \
  -e CELLD_BOOTSTRAP=0 \
  -e PORT=8080 \
  -p "127.0.0.1:${PORT}:8080" \
  "$IMAGE" >/dev/null

healthy=""
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PORT}/__celld/health" | grep -q '"ok":true'; then
    healthy=1
    break
  fi
  sleep 1
done
[[ -n "$healthy" ]] || fail "node did not become healthy"
pass "reserved health endpoint is healthy"

body="$(curl -fsS "http://127.0.0.1:${PORT}/smoke")"
[[ "$body" == *'"path":"/smoke"'* ]] || fail "Worker route returned: $body"
pass "public requests reach the deployed Worker"

uid="$(docker exec "$NAME" stat -c '%u' /var/lib/celld/state)"
[[ "$uid" = "10001" ]] || fail "state directory UID is $uid, expected 10001"
process_uid="$(docker exec "$NAME" sh -c 'grep "^Uid:" /proc/1/status | awk "{print \\$2}"')"
[[ "$process_uid" = "10001" ]] || fail "PID 1 UID is $process_uid, expected 10001"
pass "runtime is unprivileged and can write the root-owned volume"

echo "==> graceful stop"
docker stop --time 40 "$NAME" >/dev/null
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$NAME")"
[[ "$exit_code" = "0" ]] || fail "SIGTERM stop exited $exit_code"
pass "SIGTERM reaches celld and exits cleanly"

echo
echo "All smoke tests passed."
