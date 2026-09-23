# celld on Railway

[![CI](https://github.com/joeychilson/railway-celld/actions/workflows/ci.yml/badge.svg)](https://github.com/joeychilson/railway-celld/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/joeychilson/railway-celld)](https://github.com/joeychilson/railway-celld/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A Railway template for running [celld](https://celld.dev), a self-hosted
runtime for Cloudflare Workers and Durable Objects.

celld is alpha software. Back up important data and test upgrades before using
it in production.

## Deployment

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/celld-for-railway?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

The template provides:

- A tested celld image for AMD64 and ARM64.
- A Railway Bucket for deployments, databases, and leases.
- A volume at `/var/lib/celld` for local SQLite state and caches.
- Public Worker traffic on port `8080`.
- Private peer traffic on port `8081`.
- A starter page that is installed only when the Bucket is empty.

The Bucket is the durable source of truth for the default single-node
deployment. Keep the Bucket and service in the same Railway region.

## Deploy a Worker

A running node checks the Bucket for new deployments every 30 seconds and
adopts them without restarting. Deploy the Worker to the Bucket:

```text
curl -fsSL https://celld.dev/install.sh | CELLD_VERSION=v0.5.1 sh
npm install --global esbuild

railway link
railway run --service celld --no-local -- celld deploy .
```

Worker code requires `esbuild`; asset-only projects do not.

For continuous deployment, copy
[`examples/deploy-celld.yml`](examples/deploy-celld.yml) into the Worker
repository and add a `RAILWAY_TOKEN` project secret. The workflow installs the
pinned tools and deploys the Worker. Running nodes adopt it automatically.

Use one application per Bucket. To host multiple applications, give each one a
separate Bucket or a distinct `CELLD_BUCKET=s3://bucket/prefix` value.

## Configuration

The Railway template configures these variables automatically:

| Variable | Value | Purpose |
|---|---|---|
| `CELLD_BUCKET` | `s3://${{Bucket.BUCKET}}` | Durable fleet storage |
| `S3_ENDPOINT` | `${{Bucket.ENDPOINT}}` | Railway Bucket endpoint |
| `AWS_ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Bucket credentials |
| `AWS_SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | Bucket credentials |
| `AWS_REGION` | `${{Bucket.REGION}}` | Bucket region |
| `PORT` | `8080` | Public Worker listener |
| `CELLD_INTERNAL_PORT` | `8081` | Private peer listener |
| `CELLD_TRUST_FORWARDED_HEADERS` | `1` | Trust Railway's forwarded HTTPS headers |
| `CELLD_BOOTSTRAP` | `1` | Install the starter into an empty Bucket |
| `CELLD_LOCAL_CACHE_MAX_BYTES` | `134217728` | Local state cache limit |
| `CELLD_ASSET_CACHE_BYTES` | `134217728` | Asset cache limit |

The entrypoint uses Railway's stable `RAILWAY_SERVICE_ID` as `CELLD_NODE`
unless `CELLD_NODE` is set explicitly. Increase the cache limits when using a
larger volume.

For a manual Railway deployment, use
`ghcr.io/joeychilson/railway-celld:<version>` with these service settings:

- One replica with Serverless sleeping disabled.
- A volume mounted at `/var/lib/celld`.
- A public domain attached to port `8080`; never expose port `8081`.
- Healthcheck path `/.well-known/celld/health` with a 300-second timeout.
- Restart policy `Always`, deployment overlap `0`, and a 45-second draining
  time.

## Operations

### Scaling

Do not scale with Railway replicas. Replicas cannot share the volume and would
advertise the same private DNS name.

To add a node, duplicate the service, connect it to the same Bucket, and give
it a separate volume. Nodes discover one another through Bucket leases. Roll
nodes one at a time and review the
[celld release notes](https://github.com/denoland/celld/releases) before an
upgrade or downgrade.

In a fleet of two or more nodes, acknowledged writes can temporarily exist on
node volumes before reaching the Bucket. Treat every node volume as
durability-critical and stop nodes gracefully.

### Health

Run celld diagnostics inside the deployed service with the Railway CLI:

```text
railway link
railway ssh --service celld -- celld diagnose
```

Railway checks `/.well-known/celld/health` during deployment, but it is not a
continuous uptime monitor. Monitor that endpoint separately for production
services.

### Backup and restore

Railway volume backups do not include Railway Buckets. For a consistent
backup, install the Railway and AWS CLIs locally, stop application writes and
the celld node, then download the Bucket:

```text
mkdir celld-backup-YYYYMMDD
cd celld-backup-YYYYMMDD
railway run --service celld --no-local -- \
  sh -c 'aws s3 sync "$CELLD_BUCKET" . --endpoint-url "$S3_ENDPOINT" --no-progress'
```

Restart the node after the download completes. To restore, upload the backup
to a new Bucket, set `CELLD_BOOTSTRAP=0`, update the service's Bucket reference
variables, and redeploy.

### Security

- Never expose port `8081`; it contains unauthenticated operator routes.
- Never expose Bucket credentials to Workers or clients.
- Implement authentication in the Worker when the application requires it.
- Do not use celld for hostile multi-tenant workloads while it is alpha.

## Updates

Images are published only from GitHub releases. The wrapper uses its own
semantic version, independently from celld. Exact `X.Y.Z` and `sha-<commit>`
tags are immutable, while `X.Y` tracks the latest compatible patch release.
There is no `latest` tag.

The `celld-<version>` tag identifies the newest wrapper release built with a
specific celld version. A scheduled workflow checks for new celld releases and
opens a pull request; each update is smoke-tested and reviewed before a wrapper
release publishes the image. See [RELEASING.md](RELEASING.md) for the release
policy.

The celld 0.3.0 to 0.4.0 upgrade is a stop-the-fleet upgrade. Stop every
0.3.0 node before starting any 0.4.0 node; the two releases have incompatible
peer protocols and large Workers KV references. On Railway, stop the active
deployment before changing the healthcheck path and image. A normal redeploy
starts the replacement before stopping the old container and is not safe for
this upgrade.

## Development

```text
docker build -t railway-celld:test .
./test/smoke-test.sh railway-celld:test
```

The smoke test verifies the version pin, starter deployment, configuration
guard, health and Worker routes, non-root runtime, and graceful shutdown.

## License

[MIT](LICENSE). celld is licensed under Apache-2.0 by Deno Land Inc.
