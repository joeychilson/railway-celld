# celld on Railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/celld-for-railway?referralCode=NhCCIt&utm_medium=integration&utm_source=template&utm_campaign=generic)

A Railway-optimized template for [celld](https://celld.dev): self-hosted,
distributed Cloudflare Workers and Durable Objects with one SQLite database per
object.

The template is designed as a useful one-click deployment rather than a thin
`docker run` wrapper. It provisions a celld node, a Railway Bucket as the
durable source of truth, a local cache volume, private peer networking, public
HTTPS ingress, and an initial starter deployment.

## Architecture

```text
                         public HTTPS
                              │
                    ┌─────────▼─────────┐
                    │   celld service   │
                    │ public  :8080     │
                    │ internal:8081     │
                    └──────┬──────┬─────┘
                           │      │
              local cache │      │ S3 API (source of truth)
                           │      │
                  ┌────────▼─┐  ┌─▼────────────────┐
                  │  Volume  │  │ Railway Bucket   │
                  │ /var/lib │  │ deployments, DBs│
                  │  /celld  │  │ leases, peer key│
                  └──────────┘  └──────────────────┘
```

Railway Buckets run on Tigris. celld's storage documentation explicitly lists
Tigris as a compatible store because it supports the conditional writes and
read-after-write consistency celld uses for ownership. Keep the service and
bucket in the same Railway region for the lowest durable-write latency.

## What is optimized for Railway

- **Split networking:** the Worker listener binds dual-stack on `PORT`; the
  peer/operator listener binds separately on port `8081` and advertises the
  service's stable `RAILWAY_PRIVATE_DOMAIN`.
- **Private internal API:** only port `8080` gets a public Railway domain. Never
  expose `8081`; celld's operator routes on that listener are intentionally
  unauthenticated.
- **Correct healthcheck:** Railway checks celld's reserved
  `/__celld/health` path, not the deployed Worker's routes.
- **Graceful shutdown:** celld receives `SIGTERM` as PID 1. Railway allows 45
  seconds before `SIGKILL`, longer than celld's 25-second default handoff
  deadline.
- **No mixed-version overlap:** deployment overlap is disabled, one replica is
  configured, and the volume prevents simultaneous old/new mounts. This is
  important while celld releases can have non-rolling upgrade boundaries.
- **Persistent warm state:** `/var/lib/celld` stores local SQLite working files
  and caches. The Railway Bucket remains the durable source of truth.
- **Unprivileged runtime:** the entrypoint prepares Railway's root-owned volume
  and then runs celld as UID/GID `10001`.
- **Empty-bucket bootstrap:** a signed S3 `HEAD` checks for
  `deploy/current.json`. The bundled asset-only starter is installed only when
  that pointer does not exist, so an existing application is never replaced.
- **Always on:** Railway application sleeping is disabled because celld serves
  WebSockets, alarms, and ownership leases.

## Template configuration

Create these resources in the Railway template composer.

### `Bucket`

Add a Railway Bucket. The person deploying the template chooses its region.

### `celld`

Use the public image `ghcr.io/joeychilson/railway-celld:latest` as the service
source, enable Railway image auto-updates, attach a public domain on port
`8080`, and attach a volume at `/var/lib/celld`.

Set these service variables:

| Variable | Template value | Purpose |
|---|---|---|
| `CELLD_BUCKET` | `s3://${{Bucket.BUCKET}}` | Fleet bucket |
| `S3_ENDPOINT` | `${{Bucket.ENDPOINT}}` | Railway's S3 endpoint |
| `AWS_ACCESS_KEY_ID` | `${{Bucket.ACCESS_KEY_ID}}` | Bucket credential |
| `AWS_SECRET_ACCESS_KEY` | `${{Bucket.SECRET_ACCESS_KEY}}` | Bucket credential |
| `AWS_REGION` | `${{Bucket.REGION}}` | Signing/storage region |
| `PORT` | `8080` | Public Worker listener |
| `CELLD_INTERNAL_PORT` | `8081` | Private peer/operator listener |
| `CELLD_BOOTSTRAP` | `1` | Install the starter only if the bucket is empty |
| `CELLD_LOCAL_CACHE_MAX_BYTES` | `134217728` | 128 MiB hibernated-DB cache |
| `CELLD_ASSET_CACHE_BYTES` | `134217728` | 128 MiB static-asset cache |

The conservative cache limits fit Railway's smallest volume. Increase them
when you increase the volume; celld's upstream defaults are 2 GiB for the
local DB cache and 512 MiB for assets.

## Deploy your Worker

celld loads a committed deployment when a node starts. From your Wrangler
project:

```bash
# One-time local tools
curl -fsSL https://celld.dev/install.sh | sh
npm install --global esbuild  # Worker code needs it; asset-only projects do not

# Link this directory to the Railway project, then inject the celld service's
# bucket variables into the local deploy command.
railway link
railway run --service celld -- celld deploy .

# Restart the node so it loads the newly committed deployment. This keeps the
# current tested container image and does not wait for an image update.
railway restart --service celld --yes
```

The starter page is replaced by your app. The public domain and fleet bucket do
not change.

A fleet bucket runs **one application deployment**. Use a separate bucket or a
unique `s3://bucket/prefix` for each independent application.

### Deploy automatically with GitHub Actions

Use the copy-ready
[`examples/github-actions/deploy-celld.yml`](examples/github-actions/deploy-celld.yml)
workflow in your **Wrangler application repository**:

1. In Railway, open the deployed project and create a project token for the
   target environment under **Project Settings → Tokens**.
2. In the application repository, add that token as a GitHub Actions repository
   secret named `RAILWAY_TOKEN`.
3. Copy the example to `.github/workflows/deploy.yml` in that repository.
4. Adjust `CELLD_PROJECT_PATH` for a monorepo, `RAILWAY_SERVICE` if the service
   was renamed, and `CELLD_VERSION` when intentionally upgrading celld.
5. If the project uses pnpm, Yarn, or Bun, replace the example's npm dependency
   step with the appropriate frozen-lockfile install.

Pushes to `main` then install an attested celld release, run `celld deploy`
with the bucket variables injected from Railway, and restart the node. Railway's
restart command waits for the configured `/__celld/health` check to pass.

The project token can read the celld service variables, including the
fleet-administrator bucket credentials. Scope it to the intended environment,
store it only as a GitHub secret, and do not expose this workflow to untrusted
pull-request code. The workflow serializes deployments because celld publishes
one fleet-wide deployment pointer and a node loads it only at startup.

## Add nodes

Do not scale this volume-backed service with Railway replicas. Replicas cannot
use volumes, and every replica would advertise the same service DNS name.
Instead, duplicate the celld service for each additional node:

1. Point every node at the same Bucket variables.
2. Give each node a distinct Railway service name/private domain.
3. Keep internal port `8081` private.
4. Attach a separate `/var/lib/celld` volume to each node.
5. Roll nodes one at a time and follow the release's upgrade notes.

The nodes discover one another through bucket leases; there is no join service.

## Container versioning and automatic updates

The template uses **our** tested channel:

```text
ghcr.io/joeychilson/railway-celld:latest
```

It deliberately does **not** run `ghcr.io/denoland/celld:latest` directly.
`Dockerfile` pins an immutable official upstream release via
`ARG CELLD_VERSION`. [`publish-image.yml`](.github/workflows/publish-image.yml)
builds the wrapper, smoke-tests it, and only then publishes multi-platform
Linux images for AMD64 and ARM64.

Each publication gets four tags:

| Tag | Mutability | Purpose |
|---|---|---|
| `latest` | Mutable | Tested update channel used by the Railway template |
| `celld-0.2.0` | Mutable | Latest wrapper revision for one upstream celld release |
| `0.2.0-r<run>.<attempt>` | Immutable | Human-readable celld version plus Railway-wrapper revision |
| `sha-<commit>` | Immutable | Exact source rollback and audit tag |

This versions the image *with* the celld version while retaining a packaging
revision. A bare `0.2.0` tag would be ambiguous: a fix to the Railway entrypoint
might need a new container even when celld itself remains at `0.2.0`.

Every six hours, [`update-celld.yml`](.github/workflows/update-celld.yml):

1. checks the latest non-prerelease GitHub release from `denoland/celld`;
2. updates the immutable upstream and example deployment-workflow pins;
3. builds and smoke-tests the candidate;
4. commits only when those tests pass; and
5. dispatches the image publisher, which tests again before moving `latest`.

Railway monitors the digest behind the non-semantic `latest` tag. With image
auto-updates enabled, it redeploys during the configured maintenance window
when this workflow publishes a new tested digest. Railway creates a volume
backup first for eligible Pro deployments.

For production fleets, immutable tags remain available for pinning and
rollback. Review the [celld release notes](https://github.com/denoland/celld/releases)
before updating multiple nodes: celld is alpha and a release may require a
coordinated non-rolling upgrade. The template's default one-node,
volume-backed service has overlap disabled so old and new images are not run
simultaneously.

## Security and operational notes

- celld is currently alpha and is not safe for hostile multi-tenant use.
- Bucket credentials are fleet-administrator credentials. Keep them scoped to
  this bucket and never expose them to Worker code or clients.
- The internal listener has unauthenticated operator endpoints. Railway's
  encrypted private network is the security boundary; do not add a public
  domain or TCP proxy for port `8081`.
- celld does not authenticate the public application. Implement authentication
  in your Worker. Railway terminates public TLS.
- Railway Bucket API traffic currently uses public networking, although the
  bucket itself is private and requires credentials.
- Back up important data and test restoration/upgrade procedures before using
  celld for production workloads.

Read the upstream [security](https://github.com/denoland/celld/blob/main/docs/security.md),
[limitations](https://github.com/denoland/celld/blob/main/docs/limitations.md),
and [operations](https://celld.dev/docs/) documentation.

## Local development

```bash
docker build -t railway-celld:test .
./test/smoke-test.sh railway-celld:test
```

The smoke test uses celld's local test-script mode, so it does not need external
object storage. It verifies the CLI pin, starter build, config guard, health and
Worker routes, non-root volume access, and graceful shutdown.

## License

MIT. celld itself is Apache-2.0 licensed by Deno Land Inc.
