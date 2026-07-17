FROM node:24.15.0-alpine AS build
WORKDIR /workspace
RUN corepack enable && corepack prepare pnpm@9.15.5 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY apps/remote/package.json apps/remote/package.json
RUN pnpm install --frozen-lockfile --filter @paperboard/remote --prod=false
COPY apps/remote apps/remote
RUN pnpm --filter @paperboard/remote build && pnpm deploy --filter @paperboard/remote --prod /output

FROM node:24.15.0-alpine
RUN apk add --no-cache bash openssh-client tini su-exec \
    && addgroup -S paperboard && adduser -S -G paperboard -h /app paperboard
WORKDIR /app
COPY --from=build --chown=paperboard:paperboard /output ./
COPY --chown=paperboard:paperboard apps/remote/public ./public
COPY scripts/paperctl.sh scripts/tablet-companion.sh /opt/paperboard/scripts/
COPY apps/remote/container-entrypoint.sh /usr/local/bin/paperboard-remote-entrypoint
RUN chmod 755 /opt/paperboard/scripts/*.sh /usr/local/bin/paperboard-remote-entrypoint
ENV NODE_ENV=production PAPER_REMOTE_BIND=0.0.0.0 PAPER_REMOTE_PORT=4174 PAPERBOARD_REPOSITORY_ROOT=/opt/paperboard
EXPOSE 4174
ENTRYPOINT ["/usr/local/bin/paperboard-remote-entrypoint"]
CMD ["/sbin/tini", "--", "node", "dist/main.js"]
