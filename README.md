# flags-api — Do Dev à Produção: containerização de uma API Node.js

Entrega do desafio **Full Cycle 4.0 — Docker e Containers** (fork de
[devfullcycle/fc4-desafio-docker-node-api](https://github.com/devfullcycle/fc4-desafio-docker-node-api)).
O código da aplicação (`src/`, `package.json`, `package-lock.json`, `tsconfig.json`, migrações) **não foi alterado**.

## Sobre a entrega

A API de feature flags (Node.js 22 + TypeScript + PostgreSQL) ganhou toda a camada de containers em um único
`Dockerfile` multi-stage com três estágios: `dev` (todas as dependências, `tsx watch`, usuário não-root),
`build` (compila para `dist/` e poda as dependências para produção) e `production` (imagem **distroless**,
sem shell nem gerenciador de pacotes, rodando como `nonroot`, com `HEALTHCHECK` e labels OCI).
Em ambos os ambientes as migrações são aplicadas automaticamente por um serviço de execução única (`migrate`),
e o `app` só sobe depois de o banco estar saudável e a migração ter terminado com sucesso.

O ambiente de desenvolvimento (`compose.yaml`) prioriza produtividade: `develop.watch` sincroniza `src/` para dentro
do container sem rebuild (o `tsx watch` recarrega sozinho) e reconstrói a imagem quando `package.json`/`package-lock.json`
mudam; o Adminer fica disponível sob o profile `tools`. O ambiente de produção (`compose.prod.yaml`) prioriza o mínimo:
consome a imagem publicada no Docker Hub (multi-arch amd64/arm64, com SBOM e provenance), sem `build`, sem bind mount,
com restart policy, limites de CPU/memória, sistema de arquivos somente-leitura e sem capabilities.

## Imagem no Docker Hub

- Repositório: **https://hub.docker.com/r/tchesco2000/flags-api**
- Tags: `1.0.0` (semver) e `latest`, ambas apontando para o mesmo digest.

```bash
docker pull tchesco2000/flags-api:1.0.0
```

Digest do manifest list (multi-arch):

```
sha256:9a215abef451587ae5bc2a5943b2a52dfdf4e46eafe553ba0c4bb7e3ff756815
```

Comparação de tamanho (`docker image ls`, mesma arquitetura):

| Imagem | linux/amd64 | linux/arm64 |
|---|---|---|
| `dev` (node:22-alpine + todas as deps) | 210 MB | 292 MB |
| `production` (distroless + deps de produção, publicada) | **155 MB** | 163 MB¹ |

A imagem de produção fica com **~74 %** do tamanho da de dev em amd64 e bem abaixo do limite de 350 MB
(medido com `docker pull --platform linux/amd64 tchesco2000/flags-api:1.0.0 && docker image ls`).

¹ Medido em Docker 20.10; o Docker 29 reporta 227 MB para a mesma imagem arm64 (`docker image ls` mudou a forma de contar camadas compartilhadas). O critério do desafio é o tamanho em amd64.

## Decisões técnicas

### Imagem base de produção: `gcr.io/distroless/nodejs22-debian13:nonroot`

Candidatas avaliadas, todas com a mesma aplicação em cima (tamanho amd64 por `docker image ls`; CVEs pelo
`docker scout cves` da imagem final):

| Base | Base pura | Imagem final | Shell / gerenciador de pacotes | Não-root pronto | Scout (imagem final) |
|---|---|---|---|---|---|
| `node:22.23.3-bookworm-slim` | 227 MB | — | sim (bash, apt) | `node` (1000) | não medida: maior das três, descartada pelo tamanho |
| `node:22.23.3-alpine3.24` | 167 MB | 170 MB | sim (busybox sh, apk) | `node` (1000) | 0 C / **8 H** / 6 M / 1 L — as 8 HIGH estão nas dependências do **npm** que vem na imagem (`brace-expansion`, `pacote`, `sigstore`, `ip-address`, `picomatch`), coisa que a aplicação nem usa em produção |
| `distroless/nodejs22-debian12:nonroot` | 147 MB | 150 MB | não | `nonroot` (65532) | **1 C** / 11 H — o Node dela é o **22.22.0**; a CRITICAL (CVE-2025-55130) tem correção na 22.22.2 → **reprovada** pelo critério "zero CRITICAL com fix" |
| **`distroless/nodejs22-debian13:nonroot`** | 153 MB | **155 MB** | **não** | **`nonroot` (65532)** | **0 C / 0 H** / 2 M / 0 L — Node **22.23.3**, o mesmo do `dev`/`build` |

Escolhi o **distroless** porque ele entrega o menor tamanho **e** a menor superfície de ataque ao mesmo tempo:
não há `sh`, `apk`/`apt`, `npm` nem utilitários — um atacante que consiga executar código na aplicação não tem
ferramentas para pivotar, e o Scout tem muito menos pacotes para reportar (102 pacotes contra 289 na variante alpine).
A tag `nonroot` já define `USER nonroot` (uid 65532). Como a tag é móvel, ela está **fixada também por digest** no
`Dockerfile`.

A primeira tentativa foi a `nodejs22-debian12`, e o Scout a reprovou: o Google ainda empacota o Node 22.22.0 nela, com uma
CVE CRITICAL corrigida upstream. A `nodejs22-debian13` já traz o 22.23.3 e zerou CRITICAL e HIGH. É o caso clássico da
dica do enunciado: CVE CRITICAL com fix se resolve trocando a base, não convivendo com ela.

A alternativa `node:22-alpine` foi a segunda colocada: 15 MB maior na imagem final, traz shell e `apk` (bom para
depurar, ruim para a superfície de ataque), usa musl (diferenças de comportamento em DNS e bibliotecas nativas) e
carrega o `npm` com 8 HIGH que não têm relação com a aplicação. Como o app não tem dependências nativas, o argumento
decisivo foi superfície de ataque. O custo do distroless é a ausência de shell (`docker exec app sh` não existe) —
mitigado porque o `HEALTHCHECK` usa o próprio `node` com `fetch` global, e para depurar dá para usar `docker debug`
ou um sidecar.

### Estratégia de cache de build

1. **Metadados antes do código**: `package.json` e `package-lock.json` são copiados sozinhos e o `npm ci` roda antes
   de copiar `src/`. Uma alteração em código não invalida a camada de dependências.
2. **`RUN --mount=type=cache` no diretório do npm** (`/home/node/.npm` no `dev`, com `uid=1000,gid=1000`, e `/root/.npm`
   no `build`): o cache de tarballs do npm sobrevive entre builds mesmo quando a camada precisa ser refeita, e não
   entra na imagem final.
3. **Estágio `build` sempre na plataforma do host** (`FROM --platform=$BUILDPLATFORM`): o TypeScript é compilado e as
   dependências de produção instaladas **uma vez, nativamente**, sem QEMU. Como as dependências de produção são
   JavaScript puro (verificado: nenhum `.node`/`.so` em `node_modules`), o mesmo `node_modules` é copiado para as
   imagens amd64 e arm64. O estágio `production` só faz `COPY`, então o build multi-arch não executa nada emulado.
4. **`npm ci --omit=dev` em um `node_modules` limpo** (`rm -rf node_modules && npm ci --omit=dev`) em vez de `npm prune`,
   para a árvore de produção ser determinística a partir do lockfile.
5. `.dockerignore` mantém `node_modules`, `dist`, `.git`, `.env`, compose, README e relatórios fora do contexto, o que
   deixa o contexto pequeno e evita que um `dist/` local vaze para a imagem.

### Outras decisões

- **Migrações como serviço de execução única** (`migrate`): usa a mesma imagem do `app` com `command` diferente
  (`npm run db:migrate` no dev, `dist/db/migrate.js` na produção). O `app` depende de `db: service_healthy` e
  `migrate: service_completed_successfully`. Isso evita colocar shell/script de inicialização na imagem distroless e
  deixa o `ENTRYPOINT` em exec form com o `node` como PID 1, recebendo `SIGTERM` diretamente.
- **`USER 1000:1000` no `dev`** (uid/gid do usuário `node` da imagem oficial), em forma numérica: runtimes que
  checam `runAsNonRoot` conseguem provar que não é root sem ler `/etc/passwd`. `/app` pertence a esse usuário para
  o `npm ci` e o sync do `compose watch` funcionarem sem root.
- **`HEALTHCHECK` com `node -e fetch(...)`**: a base não tem `curl`/`wget`; o Node 22 tem `fetch` global.
- **Endurecimento do `app` em produção**: `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges` — a aplicação não
  escreve em disco, então nada disso quebra o funcionamento (validado: `GET/POST /flags` e healthcheck OK).
- **Versões fixadas em tudo**: `node:22.23.3-alpine3.24`, `postgres:17.11-alpine3.24`, `adminer:6.1.0` e o distroless por
  digest. Nenhuma tag `latest`.

## Como rodar (desenvolvimento)

Pré-requisitos: Docker Engine/Desktop recente com Compose v2 (≥ 2.22 para o `watch`) e Buildx.

```bash
cp .env.example .env
docker compose up
```

A API responde em http://localhost:3000 (`GET /flags` → `200`, `GET /health` → `{"status":"ok","db":"up"}`).
As migrações são aplicadas pelo serviço `migrate` antes de o `app` subir. Em outro terminal:

```bash
# usuário não-root
docker compose exec app id -u        # 1000

# reload automático: sync de src/ (sem rebuild) e rebuild em package.json / package-lock.json
docker compose watch                 # ou: docker compose up --watch

# cliente de banco (Adminer) — só com o profile "tools"
docker compose --profile tools up -d
# http://localhost:8081  (System: PostgreSQL, Server: db, User/Password/Database: valores do .env)
```

Teste rápido do CRUD:

```bash
curl -X POST http://localhost:3000/flags -H 'content-type: application/json' \
  -d '{"key":"dark-mode","description":"tema escuro","enabled":true}'
curl http://localhost:3000/flags
```

Para derrubar (o `-v` apaga o volume do PostgreSQL — dados de dev são descartáveis):

```bash
docker compose --profile tools down -v
```

## Como rodar (produção)

Consome a imagem publicada no Docker Hub; não faz build.

```bash
cp .env.example .env            # em produção real, os valores viriam de um gerenciador de segredos
docker compose -f compose.prod.yaml up -d
docker compose -f compose.prod.yaml ps   # app e db "healthy"; migrate "Exited (0)"
curl -i http://localhost:3000/flags       # 200
```

Encerramento gracioso (o `node` é o PID 1 e trata `SIGTERM`; medido em 0,15–0,7 s):

```bash
docker compose -f compose.prod.yaml stop app
docker compose -f compose.prod.yaml logs app | tail -3
#   Recebido SIGTERM. Encerrando graciosamente...
#   Encerramento concluído.
```

Para derrubar: `docker compose -f compose.prod.yaml down` (adicione `-v` para apagar o volume `pgdata`).

## Segurança e supply chain

### Build e publicação da imagem (como foi feito)

```bash
docker buildx create --name fc4 --driver docker-container --bootstrap
docker run --privileged --rm tonistiigi/binfmt --install arm64   # só em Docker Engine no Linux

docker buildx build --builder fc4 \
  --platform linux/amd64,linux/arm64 \
  --target production \
  --sbom=true --provenance=true \
  -t tchesco2000/flags-api:1.0.0 -t tchesco2000/flags-api:latest \
  --push .
```

### Verificações

```bash
# Usuário não-root, HEALTHCHECK e labels OCI
docker pull --platform linux/amd64 tchesco2000/flags-api:1.0.0
docker image inspect tchesco2000/flags-api:1.0.0 \
  --format 'User={{.Config.User}}{{"\n"}}Health={{json .Config.Healthcheck.Test}}{{"\n"}}Labels={{json .Config.Labels}}'
#   User=nonroot
#   Health=["CMD","/nodejs/bin/node","-e","fetch('http://127.0.0.1:' + ... + '/health')..."]
#   Labels={"org.opencontainers.image.title":"flags-api", ...description..., ...version":"1.0.0", ...source":"https://github.com/tchesco2000/fc4-desafio-docker-node-api", ...}

# Plataformas + attestations (SBOM e provenance) do manifest publicado, sem baixar a imagem
docker buildx imagetools inspect tchesco2000/flags-api:1.0.0
docker buildx imagetools inspect tchesco2000/flags-api:1.0.0 --format '{{json .SBOM}}'       | head -c 600
docker buildx imagetools inspect tchesco2000/flags-api:1.0.0 --format '{{json .Provenance}}' | head -c 600

# semver e latest apontam para o mesmo digest
docker buildx imagetools inspect tchesco2000/flags-api:1.0.0  --format '{{.Manifest.Digest}}'
docker buildx imagetools inspect tchesco2000/flags-api:latest --format '{{.Manifest.Digest}}'
```

### Docker Scout

Relatório completo: [`reports/scout-cves.txt`](reports/scout-cves.txt), gerado com
`docker scout cves tchesco2000/flags-api:1.0.0` contra a imagem publicada.

```bash
docker scout cves tchesco2000/flags-api:1.0.0
docker scout cves --only-severity critical --only-fixed tchesco2000/flags-api:1.0.0   # deve listar 0
```

Resumo do relatório (imagem `tchesco2000/flags-api:1.0.0`, digest `9a215abef451...`, 102 pacotes indexados):

| Severidade | Quantidade |
|---|---|
| CRITICAL | **0** |
| HIGH | **0** |
| MEDIUM | 2 |
| LOW | 0 |

`docker scout cves --only-severity critical --only-fixed` → `No vulnerable package detected`.

Não há CVE HIGH nem CRITICAL sem correção. As duas MEDIUM estão no pacote **`qs@6.15.3`** (dependência transitiva do
`express` 5, fixada pelo `package-lock.json`): CVE-2026-82562 (alocação sem limite) e CVE-2026-82417 (exceção não tratada),
ambas corrigidas na `qs@6.16.0`. Não foram corrigidas aqui porque o desafio proíbe alterar o `package-lock.json`;
o plano de mitigação é um `npm update qs` (ou bump do `express`) no repositório da aplicação, que resolve as duas
sem mudança de código. A superfície é pequena: o `qs` só entra no parse de query string, e a API não expõe filtros por
query.

## Validação

| Critério | Comando de verificação |
|---|---|
| `Dockerfile` único com estágios `dev`, `build`, `production` | `grep -nE '^FROM .* AS (dev\|build\|production)$' Dockerfile` |
| Nenhuma imagem com `latest`/sem tag | `grep -nE '^(FROM\|\s*image:)' Dockerfile compose.yaml compose.prod.yaml` |
| `.dockerignore` com `node_modules`, `dist`, `.git`, `.env` | `grep -nE '^(node_modules\|dist\|\.git\|\.env)$' .dockerignore` |
| Instalação de deps com `RUN --mount=type=cache` | `grep -n 'mount=type=cache' Dockerfile` |
| Builds dos estágios concluem | `docker build --target dev .` e `docker build --target production .` |
| Dev sobe sem passo manual, `GET /flags` 200 | `cp .env.example .env && docker compose up -d --wait && curl -i localhost:3000/flags` |
| `db` com healthcheck, `app` com `service_healthy` | `docker compose config \| grep -A3 -E 'healthcheck:\|condition:'` |
| Watch: sync em `src/`, rebuild em `package.json` | `docker compose watch` + editar um arquivo em `src/` (sem rebuild) e depois `package.json` (log "Rebuilding service") |
| Adminer no profile `tools` em 8081 | `docker compose --profile tools up -d && curl -I localhost:8081` |
| UID não-root no dev | `docker compose exec app id -u` → `1000` |
| `.env` ignorado, `.env.example` versionado | `git check-ignore .env && git ls-files .env.example` |
| Manifest com `linux/amd64` e `linux/arm64` | `docker buildx imagetools inspect tchesco2000/flags-api:1.0.0` |
| Attestations SBOM e provenance | `docker buildx imagetools inspect tchesco2000/flags-api:1.0.0 --format '{{json .SBOM}}'` / `'{{json .Provenance}}'` |
| `1.0.0` e `latest` no mesmo digest | os dois `imagetools inspect --format '{{.Manifest.Digest}}'` acima |
| Tamanho ≤ 350 MB em amd64 | `docker pull --platform linux/amd64 tchesco2000/flags-api:1.0.0 && docker image ls tchesco2000/flags-api` |
| `User` não-root, `HEALTHCHECK` e 4 labels OCI | `docker image inspect tchesco2000/flags-api:1.0.0 --format '{{.Config.User}} {{json .Config.Healthcheck}} {{json .Config.Labels}}'` |
| Container fica healthy pelo `HEALTHCHECK` da imagem | `docker compose -f compose.prod.yaml up -d && docker compose -f compose.prod.yaml ps` |
| `docker stop` < 10 s sem SIGKILL | `time docker compose -f compose.prod.yaml stop app` (exit code 0 em `docker compose -f compose.prod.yaml ps -a`) |
| Relatório do Scout em `reports/` | `cat reports/scout-cves.txt` |
| Zero CRITICAL com correção | `docker scout cves --only-severity critical --only-fixed tchesco2000/flags-api:1.0.0` |
| HIGH / CRITICAL sem fix justificadas | seção "Docker Scout" acima |
| Prod sem `build`, imagem por tag semver | `grep -nE 'build:\|image:' compose.prod.yaml` |
| Restart policy e limites de CPU/memória | `grep -nE 'restart:\|cpus:\|memory:' compose.prod.yaml` |
| Sem bind mount de código; volume nomeado | `grep -nE 'volumes:\|- ' compose.prod.yaml` (só `pgdata`) |
| Prod sobe, `GET /flags` 200, `app`/`db` healthy | `cp .env.example .env && docker compose -f compose.prod.yaml up -d && curl -i localhost:3000/flags && docker compose -f compose.prod.yaml ps` |
| Código da aplicação intacto | `git diff upstream/main -- src package.json package-lock.json tsconfig.json` (vazio) |
| Sem credencial hardcoded | `grep -nE 'PASSWORD\|password' Dockerfile compose.yaml compose.prod.yaml` (só `${DB_PASSWORD}`) |

## Estrutura do entregável

```
.
├── Dockerfile            # estágios dev, build, production
├── .dockerignore
├── compose.yaml          # desenvolvimento (watch, healthchecks, profile tools)
├── compose.prod.yaml     # produção (imagem do Docker Hub)
├── .env.example          # valores de desenvolvimento local
├── reports/
│   └── scout-cves.txt    # docker scout cves da imagem publicada
├── src/                  # (não alterado)
├── package.json          # (não alterado)
├── package-lock.json     # (não alterado)
├── tsconfig.json         # (não alterado)
└── README.md
```
