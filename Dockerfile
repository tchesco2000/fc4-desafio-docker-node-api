# syntax=docker/dockerfile:1.7
#
# Dockerfile multi-stage da flags-api.
#
#   dev        -> ambiente de desenvolvimento (todas as deps, tsx watch, usuario nao-root)
#   build      -> compila o TypeScript e poda as dependencias para producao
#   production -> imagem final enxuta (distroless, so dist/ + deps de producao)
#
# Versoes sempre fixadas (nunca "latest" / sem tag). O distroless e fixado
# tambem por digest, porque a tag "nonroot" e movel.

ARG NODE_VERSION=22.23.3
ARG ALPINE_VERSION=3.24
ARG DISTROLESS_DIGEST=sha256:13593b7570658e8477de39e2f4a1dd25db2f836d68a0ba771251572d23bb4f8e
ARG APP_VERSION=1.0.0

# ---------------------------------------------------------------------------
# base: pontos em comum de dev e build (imagem, WORKDIR, metadados de deps)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS base

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# /app pertence ao usuario "node" (uid 1000, ja existe na imagem oficial),
# para que npm ci e o sync do compose watch funcionem sem root.
# USER em forma numerica (uid:gid do "node"): runtimes como o Kubernetes
# (runAsNonRoot) conseguem provar que nao e root sem ler o /etc/passwd.
RUN mkdir -p /app && chown node:node /app
WORKDIR /app
USER 1000:1000

# Metadados de dependencias ANTES do restante do codigo: a camada do npm ci
# so e refeita quando package.json / package-lock.json mudam.
COPY --chown=node:node package.json package-lock.json ./

# ---------------------------------------------------------------------------
# dev: todas as dependencias (inclusive devDependencies) + reload automatico
# ---------------------------------------------------------------------------
FROM base AS dev

ENV NODE_ENV=development

# Cache de build do npm compartilhado entre builds (uid/gid do usuario node).
RUN --mount=type=cache,target=/home/node/.npm,uid=1000,gid=1000 \
    npm ci

COPY --chown=node:node . .

EXPOSE 3000
CMD ["npm", "run", "dev"]

# ---------------------------------------------------------------------------
# build: compila o TypeScript para dist/ e poda as deps para producao.
# Roda sempre na plataforma do host (BUILDPLATFORM): as dependencias de
# producao sao JavaScript puro (sem binarios nativos), entao o mesmo
# node_modules serve para amd64 e arm64 sem emulacao.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS build

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

WORKDIR /app

COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Reinstala do zero so as dependencias de producao (deterministico pelo lockfile).
RUN --mount=type=cache,target=/root/.npm \
    rm -rf node_modules && npm ci --omit=dev

# ---------------------------------------------------------------------------
# production: distroless (sem shell, sem gerenciador de pacotes, sem npm),
# usuario nao-root (nonroot, uid 65532), apenas dist/ + deps de producao.
# ---------------------------------------------------------------------------
FROM gcr.io/distroless/nodejs22-debian12:nonroot@${DISTROLESS_DIGEST} AS production

ARG APP_VERSION

LABEL org.opencontainers.image.title="flags-api" \
      org.opencontainers.image.description="API REST de feature flags em Node.js + TypeScript com PostgreSQL" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/tchesco2000/fc4-desafio-docker-node-api" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /app

# Arquivos pertencem ao root e sao somente-leitura para o processo (nonroot).
COPY --from=build /app/package.json ./package.json
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist

USER nonroot

EXPOSE 3000

# A base nao tem curl/wget: o proprio node (fetch global) valida o GET /health.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["/nodejs/bin/node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]

# Exec form: node e o PID 1 e recebe SIGTERM/SIGINT diretamente.
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["dist/server.js"]
