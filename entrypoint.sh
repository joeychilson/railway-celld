#!/bin/sh
set -eu

# celld's local SQLite files can contain application data. Keep newly created
# files private even when the image is used outside Railway.
umask 077

CELLD_BINARY="${CELLD_BINARY:-/usr/local/bin/celld}"
state_root="${CELLD_STATE_ROOT:-/var/lib/celld}"
public_port="${PORT:-8080}"
internal_port="${CELLD_INTERNAL_PORT:-8081}"
bootstrap="${CELLD_BOOTSTRAP:-0}"

valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

if ! valid_port "$public_port"; then
  echo "ERROR: PORT must be a number from 1 to 65535, not '$public_port'." >&2
  exit 1
fi
if ! valid_port "$internal_port"; then
  echo "ERROR: CELLD_INTERNAL_PORT must be a number from 1 to 65535, not '$internal_port'." >&2
  exit 1
fi
if [ "$public_port" = "$internal_port" ]; then
  echo "ERROR: PORT and CELLD_INTERNAL_PORT must use different ports." >&2
  exit 1
fi
case "$bootstrap" in
  0|1) ;;
  *) echo "ERROR: CELLD_BOOTSTRAP must be 0 or 1, not '$bootstrap'." >&2; exit 1 ;;
esac

# Railway private networking may be IPv6-only in legacy environments. A dual-
# stack bind serves both Railway's public edge and its encrypted private
# network. The private service DNS name is stable even though container IPs
# are not.
if [ -z "${CELLD_ADDR:-}" ]; then
  CELLD_ADDR="[::]:$public_port"
  export CELLD_ADDR
fi
if [ -z "${CELLD_INTERNAL_ADDR:-}" ]; then
  CELLD_INTERNAL_ADDR="[::]:$internal_port"
  export CELLD_INTERNAL_ADDR
fi
if [ -z "${CELLD_ADVERTISE:-}" ]; then
  CELLD_ADVERTISE="${RAILWAY_PRIVATE_DOMAIN:-localhost}:$internal_port"
  export CELLD_ADVERTISE
fi

# Runtime mode needs a deployment bucket. Keep celld's own help, version,
# deploy, diagnose, and test modes usable without imposing this wrapper check.
if [ "$#" -eq 0 ] \
  && [ "${CELLD_CLOUD:-0}" != "1" ] \
  && [ -z "${CELLD_TEST_SCRIPT_PATH:-}" ]; then
  case "${CELLD_BUCKET:-}" in
    s3://|gs://|'')
      cat >&2 <<'EOF'
ERROR: CELLD_BUCKET is missing or empty.

The Railway template wires this to its Bucket automatically. For a manual
installation, set CELLD_BUCKET (for example s3://my-celld-bucket) and the
matching object-storage credentials.
EOF
      exit 1
      ;;
  esac
fi

# Railway volumes are mounted root-owned. Create only the two writable cache
# roots as root, hand those to the unprivileged runtime user, then re-exec this
# script so celld itself is PID 1 and receives SIGTERM directly.
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$state_root" "$CELLD_WATCH" "$CELLD_ASSET_CACHE_DIR"
  chown celld:celld "$state_root" "$CELLD_WATCH" "$CELLD_ASSET_CACHE_DIR"
  exec gosu celld "$0" "$@"
fi

if [ -n "${RAILWAY_ENVIRONMENT_ID:-}" ] \
  && [ "${RAILWAY_VOLUME_MOUNT_PATH:-}" != "$state_root" ]; then
  echo "WARNING: no Railway volume is mounted at $state_root." >&2
  echo "WARNING: data remains durable in the bucket, but warm local state and caches" >&2
  echo "WARNING: will be restored after every redeploy." >&2
fi

# Return the HTTP status for deploy/current.json in a Railway Bucket. Railway
# Buckets use Tigris and virtual-hosted S3 URLs. curl signs the HEAD request
# with SigV4; credentials are never printed.
railway_pointer_status() {
  bucket_path="${CELLD_BUCKET#s3://}"
  bucket_name="${bucket_path%%/*}"
  if [ "$bucket_path" = "$bucket_name" ]; then
    object_key="deploy/current.json"
  else
    object_prefix="${bucket_path#*/}"
    object_prefix="${object_prefix%/}"
    object_key="$object_prefix/deploy/current.json"
  fi

  # New Railway Buckets use this virtual-hosted endpoint. Refuse to guess for
  # other providers or legacy path-style buckets.
  case "${S3_ENDPOINT:-}" in
    https://storage.railway.app|https://storage.railway.app/)
      pointer_url="https://${bucket_name}.storage.railway.app/${object_key}"
      ;;
    *) return 2 ;;
  esac

  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    return 3
  fi

  signing_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-auto}}"
  if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 30 --retry 2 --retry-all-errors \
      --request HEAD \
      --aws-sigv4 "aws:amz:${signing_region}:s3" \
      --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
      --header "x-amz-security-token: ${AWS_SESSION_TOKEN}" \
      "$pointer_url"
  else
    curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 10 --max-time 30 --retry 2 --retry-all-errors \
      --request HEAD \
      --aws-sigv4 "aws:amz:${signing_region}:s3" \
      --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
      "$pointer_url"
  fi
}

bootstrap_starter() {
  if [ "$bootstrap" != "1" ]; then
    return
  fi

  case "${CELLD_BUCKET:-}" in
    s3://*) ;;
    *)
      echo "WARNING: CELLD_BOOTSTRAP supports the Railway template's S3 bucket only; skipping." >&2
      return
      ;;
  esac

  status=""
  if status="$(railway_pointer_status)"; then
    :
  else
    rc=$?
    case "$rc" in
      2) echo "ERROR: CELLD_BOOTSTRAP=1 requires a new virtual-hosted Railway Bucket." >&2 ;;
      3) echo "ERROR: CELLD_BOOTSTRAP=1 requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2 ;;
      *) echo "ERROR: could not inspect the Railway Bucket for an existing deployment." >&2 ;;
    esac
    exit 1
  fi

  case "$status" in
    200)
      echo "entrypoint: existing celld deployment found; starter left untouched"
      return
      ;;
    404)
      echo "entrypoint: empty Railway Bucket; installing the celld starter deployment"
      if "$CELLD_BINARY" deploy /opt/celld/starter; then
        return
      fi

      # Another node may have won the compare-and-swap while this one built the
      # starter. Continue only when the committed pointer now exists.
      retry_status=""
      if retry_status="$(railway_pointer_status)" && [ "$retry_status" = "200" ]; then
        echo "entrypoint: another node committed a deployment first; continuing"
        return
      fi
      echo "ERROR: starter deployment failed and no committed deployment exists." >&2
      exit 1
      ;;
    *)
      echo "ERROR: Railway Bucket returned HTTP $status for deploy/current.json." >&2
      exit 1
      ;;
  esac
}

# Only the long-running Railway service (no command arguments) bootstraps.
# `docker run IMAGE deploy ...` remains an ordinary celld CLI invocation.
if [ "$#" -eq 0 ]; then
  bootstrap_starter
fi

exec "$CELLD_BINARY" "$@"
