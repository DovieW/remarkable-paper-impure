FROM node:24.15.0-alpine AS build
WORKDIR /workspace
ENV SHARP_IGNORE_GLOBAL_LIBVIPS=1
RUN corepack enable && corepack prepare pnpm@9.15.5 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/core/package.json packages/core/package.json
COPY apps/relay/package.json apps/relay/package.json
RUN pnpm install --frozen-lockfile --filter @paperboard/relay... --prod=false
COPY packages/core packages/core
COPY apps/relay apps/relay
RUN pnpm --filter @paperboard/core build && pnpm --filter @paperboard/relay build && pnpm deploy --filter @paperboard/relay --prod /output

FROM node:24.15.0-alpine
RUN apk add --no-cache openssh-client tini su-exec && addgroup -S paperboard && adduser -S -G paperboard -h /app paperboard \
    && mkdir -p /data && chown paperboard:paperboard /data
WORKDIR /app
COPY --from=build --chown=paperboard:paperboard /output ./
COPY apps/relay/container-entrypoint.sh /usr/local/bin/paperboard-entrypoint
COPY scripts/paperboard-tablet-bridge.sh /usr/local/bin/paperboard-tablet-bridge
RUN chmod 755 /usr/local/bin/paperboard-entrypoint /usr/local/bin/paperboard-tablet-bridge
ENV NODE_ENV=production PAPERBOARD_HOST=127.0.0.1 PAPERBOARD_PORT=8787 PAPERBOARD_ADMIN_HOST=127.0.0.1 PAPERBOARD_ADMIN_PORT=8788 PAPERBOARD_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8787 8788
ENTRYPOINT ["/usr/local/bin/paperboard-entrypoint"]
CMD ["/sbin/tini", "--", "node", "dist/main.js"]
