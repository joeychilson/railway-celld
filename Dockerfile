# syntax=docker/dockerfile:1.7

# Pin an immutable upstream release. .github/workflows/update-celld.yml checks
# for new celld releases, builds and smoke-tests them, then updates this pin.
ARG CELLD_VERSION=0.2.0
FROM ghcr.io/denoland/celld:${CELLD_VERSION}

ARG CELLD_VERSION
LABEL org.opencontainers.image.title="celld for Railway" \
      org.opencontainers.image.description="Railway-optimized celld runtime" \
      org.opencontainers.image.source="https://github.com/joeychilson/railway-celld" \
      org.opencontainers.image.base.name="ghcr.io/denoland/celld:${CELLD_VERSION}"

# curl is used only to atomically detect an empty Railway Bucket before
# installing the starter deployment. gosu lets the runtime drop root after
# preparing Railway's root-owned volume.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl gosu passwd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 celld \
    && useradd --uid 10001 --gid 10001 --home-dir /var/lib/celld \
         --shell /usr/sbin/nologin --no-create-home celld \
    && mkdir -p /var/lib/celld/state /var/lib/celld/assets \
    && chown -R celld:celld /var/lib/celld

ENV HOME=/var/lib/celld \
    CELLD_WATCH=/var/lib/celld/state \
    CELLD_ASSET_CACHE_DIR=/var/lib/celld/assets

COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-celld-entrypoint
COPY --chown=celld:celld starter/ /opt/celld/starter/

EXPOSE 8080 8081

# Railway uses railway.json's healthcheckPath. This also makes the image easy
# to operate with Docker, Podman, or Compose outside Railway.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD-SHELL curl --noproxy '*' -fsS "http://127.0.0.1:${PORT:-8080}/__celld/health" >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/railway-celld-entrypoint"]
