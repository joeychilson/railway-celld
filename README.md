# celld on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/celld-for-railway?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

One-click [celld](https://celld.dev) — self-hosted Cloudflare Workers and
Durable Objects — for Railway. The template deploys a tested celld image with
a Railway Bucket as the durable source of truth, a local cache volume, public
HTTPS on port `8080`, and private peer networking on `8081`.

```text
        public HTTPS            S3 API (source of truth)
             │                        │
      ┌──────▼────────────────┐  ┌────▼───────────┐
      │     celld service     │  │ Railway Bucket │
      │ :8080 public Workers  │  │ deployments,   │
      │ :8081 private peers   │  │ DBs, leases    │
      │ volume /var/lib/celld │  └────────────────┘
      └───────────────────────┘
          local SQLite + caches (warm state only)
```

celld is alpha software. The Bucket is the durable store for the default
single-node template; use the backup procedure below before trusting it with
production data.

## Deploy your Worker

A node loads its deployment at startup, so deploying is: build + commit to the
bucket, then restart the node. From your Wrangler project:

```bash
# One-time local tools
curl -fsSL https://celld.dev/install.sh | CELLD_VERSION=v0.3.0 sh
npm install --global esbuild  # Worker code needs it; asset-only projects do not

railway link
railway run --service celld --no-local -- celld deploy .
railway restart --service celld --yes   # waits for the healthcheck to pass
```

Your app replaces the starter page; the domain and bucket do not change.

For CI, copy the example GitHub Actions workflow
[`examples/deploy-celld.yml`](examples/deploy-celld.yml) into your application
repository and set a `RAILWAY_TOKEN` project secret. It installs an attested
celld release, deploys, and restarts the node.

**One application per bucket.** A fleet bucket holds a single deployment
pointer. Run separate apps in separate buckets, or use a distinct
`CELLD_BUCKET=s3://bucket/prefix` per app.

## Service variables

| Variable | Value | Notes |
|---|---|---|
| `CELLD_BUCKET` | `s3://${{Bucket.BUCKET}}` | Fleet bucket |
| `S3_ENDPOINT` | `${{Bucket.ENDPOINT}}` | |
| `AWS_ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Admin credentials — never expose to Workers or clients |
| `AWS_SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | |
| `AWS_REGION` | `${{Bucket.REGION}}` | Keep bucket and service in the same region |
| `PORT` | `8080` | Public Worker listener (attach the public domain here) |
| `CELLD_INTERNAL_PORT` | `8081` | Private listener — never expose publicly |
| `CELLD_TRUST_FORWARDED_HEADERS` | `1` | Workers see `https://your-domain` URLs |
| `CELLD_BOOTSTRAP` | `1` | Installs the starter only into an empty bucket |
| `CELLD_LOCAL_CACHE_MAX_BYTES` | `134217728` | Sized for the smallest volume; upstream default is 2 GiB |
| `CELLD_ASSET_CACHE_BYTES` | `134217728` | Upstream default is 512 MiB |

Raise the cache limits if you attach a larger volume.
The entrypoint automatically uses Railway's stable `RAILWAY_SERVICE_ID` as
`CELLD_NODE`; an explicitly configured `CELLD_NODE` takes precedence.

## Railway deployment settings

The image-based template must configure these settings in Railway; this
repository's `railway.json` applies only when Railway builds the repository
itself.

- Image: `ghcr.io/joeychilson/railway-celld:latest`, with image auto-updates
  enabled for the preferred maintenance window.
- Public domain: port `8080`. Do not expose port `8081`.
- Volume: mount at `/var/lib/celld`.
- Replicas: `1`; disable Serverless sleeping.
- Healthcheck: `/__celld/health`, with a 300-second timeout.
- Restart policy: `Always`.
- Deployment overlap: `0` seconds.
- Draining time: `45` seconds, longer than celld's default 25-second shutdown
  deadline.

## Add nodes

Do **not** scale this service with Railway replicas: replicas cannot use the
volume and would all advertise the same private DNS name. Instead, duplicate
the service per node — same bucket variables, distinct service name, its own
volume. Nodes discover each other through bucket leases; there is no join
command. Roll nodes one at a time and check the
[celld release notes](https://github.com/denoland/celld/releases) first: a
release may require a coordinated, non-rolling upgrade. The default one-node
service disables deploy overlap for the same reason.

Starting with celld v0.3, a fleet of two or more nodes acknowledges a write
after another node has persisted it, then uploads it to the Bucket in the
background. In that configuration each node's volume can temporarily contain
acknowledged data that has not reached the Bucket yet. Treat every node volume
as durability-critical, watch its disk usage, and stop nodes gracefully. This
does not change the default single-node template's Bucket-synchronous behavior.

## Operations

The Railway CLI is an operator tool; it is not installed in the production
image. To run celld's diagnostics inside the deployed service:

```bash
railway link
railway ssh --service celld -- celld diagnose
```

Railway's healthcheck gates a new deployment but is not a continuous uptime
monitor. Monitor the public `/__celld/health` endpoint separately for a
production service. Keep port `8081` private.

### Back up and restore the Bucket

Railway volume backups do not include the Railway Bucket, and Railway Buckets
do not currently provide point-in-time snapshots or object versioning. For a
consistent backup, stop application writes and the celld node, then download
the Bucket with the Railway CLI and AWS CLI installed locally:

```bash
mkdir celld-backup-YYYYMMDD
cd celld-backup-YYYYMMDD
railway run --service celld --no-local -- \
  sh -c 'aws s3 sync "$CELLD_BUCKET" . --endpoint-url "$S3_ENDPOINT" --no-progress'
```

Restart the node after the download finishes. To restore, create a fresh
Railway Bucket, keep `CELLD_BOOTSTRAP=0`, upload this directory to that Bucket
with `aws s3 sync`, change the celld service's Bucket reference variables, and
then redeploy. Restoring into a fresh Bucket avoids deleting or partially
overwriting the original.

## Security

- Port `8081` serves unauthenticated operator routes. The Railway private
  network is its security boundary — never give it a public domain or TCP proxy.
- Bucket credentials are fleet-administrator credentials.
- celld does not authenticate your app; implement auth in the Worker.
  Railway terminates public TLS.
- Not safe for hostile multi-tenant use while celld is alpha.

## Updates

The template image is `ghcr.io/joeychilson/railway-celld:latest` — not the raw
upstream `latest`. This repo pins an explicit celld release. A scheduled
workflow builds and smoke-tests each new upstream release, then opens a PR with
its release notes for compatibility review. Merging that PR publishes the
approved wrapper (AMD64 + ARM64), so Railway image auto-updates only receive
reviewed releases.
`celld-<version>` is a mutable channel for the latest wrapper revision on that
celld release. Unique `<version>-r<run>.<attempt>` tags and source-specific
`sha-<commit>` tags are available for pinning and rollback.

Do not assume every downgrade is safe. In particular, before downgrading a
multi-node fleet from celld v0.3 to v0.2, verify every node shut down with a
`node-log close: sealed epoch` message so no acknowledged write remains only in
the v0.3 replicated log.

## Local development

```bash
docker build -t railway-celld:test .
./test/smoke-test.sh railway-celld:test
```

The smoke test needs no object storage (it uses celld's local test-script
mode) and covers the version pin, starter build, config guard, health and
Worker routes, non-root runtime, and graceful shutdown.

## License

MIT. celld itself is Apache-2.0 licensed by Deno Land Inc.
