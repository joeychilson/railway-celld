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

celld is alpha software. The Bucket is the durable store; back it up before
trusting it with production data.

## Deploy your Worker

A node loads its deployment at startup, so deploying is: build + commit to the
bucket, then restart the node. From your Wrangler project:

```bash
# One-time local tools
curl -fsSL https://celld.dev/install.sh | CELLD_VERSION=v0.2.1 sh
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

## Security

- Port `8081` serves unauthenticated operator routes. The Railway private
  network is its security boundary — never give it a public domain or TCP proxy.
- Bucket credentials are fleet-administrator credentials.
- celld does not authenticate your app; implement auth in the Worker.
  Railway terminates public TLS.
- Not safe for hostile multi-tenant use while celld is alpha.

## Updates

The template image is `ghcr.io/joeychilson/railway-celld:latest` — not the raw
upstream `latest`. This repo pins an immutable celld release, and CI builds,
smoke-tests, and only then publishes the wrapper (AMD64 + ARM64). A scheduled
workflow bumps the pin when a new upstream release passes the same tests, so
enabling Railway image auto-updates keeps you on tested releases.
`celld-<version>` is a mutable channel for the latest wrapper revision on that
celld release. Unique `<version>-r<run>.<attempt>` tags and source-specific
`sha-<commit>` tags are available for pinning and rollback.

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
