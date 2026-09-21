# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t emcp .
# docker run -d -p 80:80 -e RAILS_MASTER_KEY=<value from config/master.key> --name emcp emcp

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Global build args must be declared before the first FROM (used by later FROM lines).
ARG RUBY_VERSION=4.0.5
ARG GWS_VERSION=0.22.5
ARG HEY_VERSION=1.6.0
ARG BASECAMP_VERSION=0.9.1
ARG OP_VERSION=2.39.0

# --- MCP CLI binaries (hey, basecamp, gws, op) ---
# Download official release tarballs. Do not git clone: GitHub prompts for a
# username inside BuildKit (no TTY) and the build fails with exit 128.
FROM debian:bookworm-slim AS basecamp-download
ARG TARGETARCH
ARG BASECAMP_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN case "${TARGETARCH}" in \
      amd64) arch="amd64" ;; \
      arm64) arch="arm64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="basecamp_${BASECAMP_VERSION}_linux_${arch}.tar.gz" \
    && url="https://github.com/basecamp/basecamp-cli/releases/download/v${BASECAMP_VERSION}" \
    && curl -fsSLO "${url}/${archive}" \
    && curl -fsSLO "${url}/checksums.txt" \
    && grep " ${archive}$" checksums.txt | sha256sum -c - \
    && tar -xzf "${archive}" \
    && mkdir -p /out \
    && install -m 0755 basecamp /out/basecamp

FROM debian:bookworm-slim AS hey-download
ARG TARGETARCH
ARG HEY_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN case "${TARGETARCH}" in \
      amd64) arch="amd64" ;; \
      arm64) arch="arm64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="hey_${HEY_VERSION}_linux_${arch}.tar.gz" \
    && url="https://github.com/basecamp/hey-cli/releases/download/v${HEY_VERSION}" \
    && curl -fsSLO "${url}/${archive}" \
    && curl -fsSLO "${url}/checksums.txt" \
    && grep " ${archive}$" checksums.txt | sha256sum -c - \
    && tar -xzf "${archive}" \
    && mkdir -p /out \
    && install -m 0755 hey /out/hey

FROM debian:bookworm-slim AS gws-download
ARG TARGETARCH
ARG GWS_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN case "${TARGETARCH}" in \
      amd64) target="x86_64-unknown-linux-gnu" ;; \
      arm64) target="aarch64-unknown-linux-gnu" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="google-workspace-cli-${target}.tar.gz" \
    && url="https://github.com/googleworkspace/cli/releases/download/v${GWS_VERSION}" \
    && curl -fsSLO "${url}/${archive}" \
    && curl -fsSLO "${url}/${archive}.sha256" \
    && sha256sum -c "${archive}.sha256" \
    && tar -xzf "${archive}" \
    && mkdir -p /out \
    && install -m 0755 gws /out/gws

FROM debian:bookworm-slim AS op-download
ARG TARGETARCH
ARG OP_VERSION
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp
RUN case "${TARGETARCH}" in \
      amd64) arch="amd64" ;; \
      arm64) arch="arm64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && archive="op_linux_${arch}_v${OP_VERSION}.zip" \
    && url="https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_VERSION}/${archive}" \
    && curl -fsSLO "${url}" \
    && unzip -o "${archive}" \
    && mkdir -p /out \
    && install -m 0755 op /out/op

FROM docker.io/library/golang:1.27-bookworm AS whatsapp-bridge-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY servers/whatsapp/bridge/go.mod servers/whatsapp/bridge/go.sum ./
RUN GOPROXY=https://proxy.golang.org,direct \
    bash -c 'for i in 1 2 3 4 5; do go mod download && exit 0; echo "go mod download retry $i"; sleep $((i * 4)); done; exit 1'
COPY servers/whatsapp/bridge/ ./
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/whatsapp-bridge .

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libsqlite3-0 ca-certificates \
      python3 python3-pip python3-venv && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    python3 -m venv /opt/hass-cli && \
    /opt/hass-cli/bin/pip install --no-cache-dir homeassistant-cli && \
    ln -sf /opt/hass-cli/bin/hass-cli /usr/local/bin/hass-cli && \
    printf '%s\n' \
      '# Prefer IPv4. Docker DNS often returns AAAA for Google APIs while the' \
      '# container has no working IPv6, which surfaces as getaddrinfo/dns errors.' \
      'precedence ::ffff:0:0/96  100' \
      'precedence ::/0            40' \
      'precedence 2002::/16       30' \
      'precedence ::/96           20' \
      'precedence ::1/128         10' \
      > /etc/gai.conf && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# CLI config/cache live under the mounted storage volume so tokens survive deploys.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so" \
    HOME="/rails/storage/home" \
    HEY_NO_KEYRING="1" \
    HEY_NONINTERACTIVE="1" \
    BASECAMP_NO_KEYRING="1" \
    GOOGLE_WORKSPACE_CLI_CONFIG_DIR="/rails/storage/home/.config/gws" \
    GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND="file" \
    OP_CONFIG_DIR="/rails/storage/mcp/onepassword/config" \
    OP_CACHE="false"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libsqlite3-dev libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile




# Final stage for app image
FROM base

# MCP CLI binaries
COPY --from=basecamp-download /out/basecamp /usr/local/bin/basecamp
COPY --from=hey-download /out/hey /usr/local/bin/hey
COPY --from=gws-download /out/gws /usr/local/bin/gws
COPY --from=op-download /out/op /usr/local/bin/op
COPY --from=whatsapp-bridge-build /out/whatsapp-bridge /usr/local/bin/whatsapp-bridge

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
