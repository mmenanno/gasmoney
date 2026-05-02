# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=4.0.3
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /app

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean && \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      curl \
      gosu \
      libjemalloc2 \
      sqlite3 \
      tini

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development test" \
    RACK_ENV=production \
    RUBY_YJIT_ENABLE=1 \
    GASMONEY_DB_PATH=/app/state/gasmoney.sqlite3 \
    PORT=9292

# ---- gems stage ----
FROM base AS gems
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libyaml-dev \
      pkg-config \
      libsqlite3-dev

COPY --link Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf \
      ~/.bundle/ \
      "${BUNDLE_PATH}"/ruby/*/cache \
      "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# ---- source consolidation stage ----
# Stages every small runtime artifact so the final image picks them up
# in a single COPY. Avoids the per-layer overhead that dominates when
# the file groups are themselves tiny (a few KB each).
FROM base AS source
COPY --link lib    ./lib
COPY --link views  ./views
COPY --link public ./public
COPY --link bin/start bin/init ./bin/
COPY --link app.rb config.ru Gemfile Gemfile.lock VERSION ./

# ---- final runtime ----
FROM base
ARG BUILD_SHA=""
ARG BUILD_REF=""
ARG BUILD_VERSION=""
ENV BUILD_SHA=$BUILD_SHA \
    BUILD_REF=$BUILD_REF \
    BUILD_VERSION=$BUILD_VERSION \
    LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 \
    MALLOC_CONF=background_thread:true,dirty_decay_ms:1000,muzzy_decay_ms:1000

COPY --link --from=gems   "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --link --from=source /app /app

# User creation comes after the COPYs — its layer changes every build
# (useradd embeds today's date), so keeping it at the tail of the manifest
# means downstream consumers (e.g. Unraid's pull UI) don't re-fetch the
# large stable layers above on every rebuild.
RUN set -eux; \
    groupadd --gid 1000 app; \
    useradd --uid 1000 --gid app --create-home --shell /bin/bash app; \
    mkdir -p /app/state /app/log; \
    chown -R 1000:1000 /app/state /app/log; \
    chmod +x /app/bin/init /app/bin/start

EXPOSE 9292
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS "http://localhost:${PORT:-9292}/health" || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/app/bin/init"]
