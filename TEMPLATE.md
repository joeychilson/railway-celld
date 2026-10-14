# Deploy and Host celld with Railway

celld runs Cloudflare Workers and Durable Objects on infrastructure you
control. This template runs a celld node with a Railway Bucket for durable
storage, a volume for local state, and a starter page, with every variable
configured for you. celld is alpha software, so back up important data and
read the release notes before upgrading.

## About Hosting celld

celld needs S3-compatible object storage for deployments and Durable Object
data, plus local disk for SQLite working files and caches. The template creates
a Railway Bucket, attaches a volume at `/var/lib/celld`, wires the Bucket
credentials into the service, and exposes only the public Worker listener on
port `8080`. The operator and peer listener on port `8081` stays on Railway's
private network. When the Bucket is empty, the node installs a starter page.
Running nodes check the Bucket every 30 seconds and adopt a new deployment
without restarting.

## Common Use Cases

- Self-hosting Cloudflare Workers and Durable Objects
- Stateful applications with one SQLite database per object
- Chat rooms, counters, coordinators, and WebSocket services

## Dependencies for celld Hosting

- A Railway Bucket for deployments and durable application data
- A Railway volume for local SQLite files and caches
- The celld CLI, and `esbuild` for Worker code, on the machine you deploy from

### Deployment Dependencies

- [celld documentation](https://celld.dev/docs/)
- [celld source code](https://github.com/denoland/celld)
- [Template source and full README](https://github.com/joeychilson/railway-celld)

### Implementation Details

From a local Wrangler project, deploy a Worker to the Bucket with the service's
variables:

```bash
railway link
railway run --service celld --no-local -- celld deploy .
```

The node picks up the new deployment within 30 seconds. Never expose port
`8081`, and don't scale with Railway replicas: to add a node, duplicate the
service with its own volume and the same Bucket.

### Why Deploy celld on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will
host your infrastructure so you don't have to deal with configuration, while
allowing you to vertically and horizontally scale it.

By deploying celld on Railway, you are one step closer to supporting a complete
full-stack application with minimal burden. Host your servers, databases, AI
agents, and more on Railway.
