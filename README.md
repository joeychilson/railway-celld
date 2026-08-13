# celld on Railway

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

Use this GitHub repository as the service source, attach a public domain on
port `8080`, and attach a volume at `/var/lib/celld`.

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

# Restart the node so it loads the newly committed deployment.
railway redeploy --service celld --yes
```

The starter page is replaced by your app. The public domain and fleet bucket do
not change.

A fleet bucket runs **one application deployment**. Use a separate bucket or a
unique `s3://bucket/prefix` for each independent application.

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

## Versioning and automatic updates

This repository deliberately **does not use `ghcr.io/denoland/celld:latest`**.
`Dockerfile` pins an immutable official release, currently expressed as
`ARG CELLD_VERSION`.

Every six hours, [`update-celld.yml`](.github/workflows/update-celld.yml):

1. checks the latest non-prerelease GitHub release from `denoland/celld`;
2. updates the exact image pin;
3. builds the Railway wrapper and runs its smoke tests; and
4. commits the pin to `main` only if those tests pass.

That gives new template deployments the newest tested celld release without a
mutable tag changing underneath a build. Railway also detects updates to a
GitHub-backed template and notifies existing users. Applying a template update
is intentionally opt-in: celld is alpha, and releases may require a coordinated
non-rolling upgrade. Review the [celld release notes](https://github.com/denoland/celld/releases)
before applying an update to a multi-node fleet.

Railway can auto-redeploy mutable image tags, but using upstream `latest`
directly would bypass this template's private-network setup, empty-bucket
bootstrap, volume permissions, and candidate smoke test. It would also make an
incompatible alpha upgrade automatic. The tested immutable-pin workflow is the
safer default.

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
