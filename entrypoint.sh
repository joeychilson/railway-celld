#!/bin/sh
set -eu

# celld's local SQLite files can contain application data. Keep newly created
# files private even when the image is used outside Railway.
umask 077

# Railway private networking may be IPv6-only in legacy environments. A dual-
# stack bind serves both Railway's public edge and its encrypted private
# network. Peers reach this node by the stable private DNS name, not by its
# container IP. celld validates both addresses itself and fails fast on a
# bad or colliding port.
CELLD_ADDR="${CELLD_ADDR:-[::]:${PORT:-8080}}"
CELLD_INTERNAL_ADDR="${CELLD_INTERNAL_ADDR:-[::]:${CELLD_INTERNAL_PORT:-8081}}"
CELLD_ADVERTISE="${CELLD_ADVERTISE:-${RAILWAY_PRIVATE_DOMAIN:-localhost}:${CELLD_INTERNAL_PORT:-8081}}"
export CELLD_ADDR CELLD_INTERNAL_ADDR CELLD_ADVERTISE

# Railway volumes are mounted root-owned. Create the writable roots as root,
# hand them to the unprivileged runtime user, then re-exec this script so
# celld itself is PID 1 and receives SIGTERM directly.
if [ "$(id -u)" = "0" ]; then
  mkdir -p /var/lib/celld "$CELLD_WATCH" "$CELLD_ASSET_CACHE_DIR"
  chown celld:celld /var/lib/celld "$CELLD_WATCH" "$CELLD_ASSET_CACHE_DIR"
  exec gosu celld "$0" "$@"
fi

# HTTP status of deploy/current.json, the fleet-wide deployment pointer.
# celld addresses every explicit S3 endpoint with path-style requests, so the
# probe does too: any endpoint that can serve the node can serve this check,
# on every Railway Bucket generation and any S3-compatible store. curl signs
# the HEAD with SigV4; credentials are never printed. Returns 2 without an
# endpoint, 3 without credentials.
pointer_status() {
  path="${CELLD_BUCKET#s3://}"
  bucket="${path%%/*}"
  if [ "$path" = "$bucket" ]; then
    key="deploy/current.json"
  else
    key="${path#*/}"
    key="${key%/}/deploy/current.json"
  fi

  endpoint="${S3_ENDPOINT:-}"
  case "$endpoint" in
    https://?*|http://?*) endpoint="${endpoint%/}" ;;
    *) return 2 ;;
  esac
  if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    return 3
  fi

  if [ -n "${AWS_SESSION_TOKEN:-}" ]; then
    set -- --header "x-amz-security-token: ${AWS_SESSION_TOKEN}"
  fi
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --head --connect-timeout 10 --max-time 30 --retry 2 --retry-all-errors \
    --aws-sigv4 "aws:amz:${AWS_REGION:-${AWS_DEFAULT_REGION:-auto}}:s3" \
    --user "${AWS_ACCESS_KEY_ID}:${AWS_SECRET_ACCESS_KEY}" \
    "$@" "${endpoint}/${bucket}/${key}"
}

# Install the bundled asset-only starter when the fleet bucket has no
# deployment yet, so a fresh template serves a page instead of erroring. An
# existing deployment is never replaced. A failed install exits nonzero for
# Railway's ALWAYS restart policy to retry.
bootstrap_starter() {
  case "${CELLD_BOOTSTRAP:-0}" in
    0) return ;;
    1) ;;
    *) echo "ERROR: CELLD_BOOTSTRAP must be 0 or 1, not '${CELLD_BOOTSTRAP:-}'." >&2; exit 1 ;;
  esac

  case "${CELLD_BUCKET:-}" in
    s3://?*) ;;
    *) echo "WARNING: CELLD_BOOTSTRAP needs an s3:// bucket; skipping." >&2; return ;;
  esac

  status="$(pointer_status)" || {
    case "$?" in
      2) echo "ERROR: CELLD_BOOTSTRAP=1 requires an http(s) S3_ENDPOINT." >&2 ;;
      3) echo "ERROR: CELLD_BOOTSTRAP=1 requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY." >&2 ;;
      *) echo "ERROR: could not inspect the bucket for an existing deployment." >&2 ;;
    esac
    exit 1
  }

  case "$status" in
    200)
      echo "entrypoint: existing deployment found; starter left untouched"
      ;;
    404)
      echo "entrypoint: empty bucket; installing the celld starter deployment"
      /usr/local/bin/celld deploy /opt/celld/starter
      ;;
    *)
      echo "ERROR: bucket returned HTTP $status for deploy/current.json." >&2
      exit 1
      ;;
  esac
}

# Only the long-running service (no command arguments) is the Railway node.
# `docker run IMAGE deploy ...` stays an ordinary celld CLI invocation.
if [ "$#" -eq 0 ]; then
  case "${CELLD_BUCKET:-}" in
    s3://?*|gs://?*) ;;
    *)
      # The runtime needs a bucket; celld's own managed and test modes manage
      # their configuration and stay usable without this wrapper check.
      if [ "${CELLD_CLOUD:-0}" != "1" ] && [ -z "${CELLD_TEST_SCRIPT_PATH:-}" ]; then
        cat >&2 <<'EOF'
ERROR: CELLD_BUCKET is missing or empty.

The Railway template wires this to its Bucket reference automatically. For a
manual installation, set CELLD_BUCKET (for example s3://my-celld-bucket) plus
its object-storage credentials.
EOF
        exit 1
      fi
      ;;
  esac

  if [ -n "${RAILWAY_ENVIRONMENT_ID:-}" ] \
    && [ "${RAILWAY_VOLUME_MOUNT_PATH:-}" != "/var/lib/celld" ]; then
    echo "WARNING: no Railway volume is mounted at /var/lib/celld; warm state and" >&2
    echo "WARNING: caches will be rebuilt after every redeploy." >&2
  fi

  bootstrap_starter
fi

exec /usr/local/bin/celld "$@"
