# osionos-ai — the AI assistant on the dev stack

The assistant lives in the osionos app repo (`services/osionos-ai`), not here. This runbook
covers only what groot adds around it: the image, the compose profile `ai`, the `/api/ai/` route
of the `:4000` vhost, and the switch that turns the feature on in the browser.

**The assistant is OFF by default.** A plain `docker compose up` starts none of it, and the app
build carries no AI URL, so the app shows no AI action and never calls the service at all (the
client has no base URL to call). Turning it on is two commands (below) and one env var.

## Start

```sh
docker compose --profile ai up -d --build
```

That starts six services, none of which publishes a port:

| Service | What it is | Image |
|---|---|---|
| `osionos-ai` | the service itself (conversations, runs, the model gateway) | `track-binocle/osionos-ai:local`, built by `infrastructure/docker/osionos/ai.Dockerfile` from the osionos submodule |
| `osionos-ai-db` | the dev Postgres of the AI tables | `pgvector/pgvector:0.8.0-pg16` |
| `osionos-ai-redis` | the run streams and the rate counters | `redis:7-alpine` |
| `osionos-ai-llm` | the dev chat model (llama.cpp, CPU, no API key) | `ghcr.io/ggml-org/llama.cpp:server-b11580` |
| `osionos-ai-embed` | the local embedder (Hugging Face TEI, CPU) | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4` |
| `osionos-ai-indexer` | the index worker (same image as the service, other entrypoint) | `track-binocle/osionos-ai:local` |

Then turn the feature on in the browser:

```sh
echo 'VITE_AI_URL=https://localhost:4000' >> .env.local
docker compose --profile dev up -d --build osionos-app
```

`VITE_AI_URL` is baked into the bundle at build time, so the app image must be rebuilt after the
value changes — a restart is not enough. It is the **only** switch: the client reads
`VITE_AI_URL` alone (`src/features/ai/api/aiClient.ts` in the osionos repo), so an app built
without it shows no AI slash command and never calls the service. The `:4000` vhost answers
`https://localhost:4000/api/ai/*` for the browser, SSE unbuffered (`proxy_buffering off`), with
the contract's 64 KB body limit (413 above it).

## The first start downloads the model

`osionos-ai-llm` pulls `unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M` (~2.5 GB) into the
`osionos_ai_models_llm` volume on its first start, and answers only when the model is there. The
healthcheck waits 900 s for it, so `docker compose ps` shows it as `starting` for a few minutes on
a cold volume. A warm volume starts in seconds. The image tag is pinned to a release that was
at least 7 days old when this was written (`b11580`, 2026-10-13) — a fresh `docker compose pull`
never runs an unreviewed binary.

## Pointing at something else

Every value below is `${NAME:-default}` in `docker-compose.yml`, so `.env.local` overrides it:

| Variable | Default | What it changes |
|---|---|---|
| `OSIONOS_AI_DATABASE_URL` | the dev Postgres of `osionos-ai-db` | a real grobase Postgres (then the pages and the workspace members are the real ones) |
| `OSIONOS_AI_DB_PASSWORD` | `osionos-ai-dev` | the password of that dev Postgres, passed to the AI service and the indexer as `PGPASSWORD` |
| `OSIONOS_AI_REDIS_URL` | `redis://osionos-ai-redis:6379` | a shared Redis (the run streams survive a restart of the service) |
| `OSIONOS_AI_UPSTREAM_BASE_URL` | `http://osionos-ai-llm:8080/v1` | another OpenAI-compatible upstream (OpenRouter: `https://openrouter.ai/api/v1` + `OSIONOS_AI_UPSTREAM_API_KEY`) |
| `OSIONOS_AI_PLATFORM_MODELS` | one local model, `qwen3-4b`, free | the platform allowlist the client sees (the ids, the labels, the prices) |
| `OSIONOS_ALLOWED_ORIGIN` | `https://localhost:3001` | the origin the service answers CORS for |
| `OSIONOS_APP_SESSION_SECRET` | — | **from `.env.local`**: the secret the bridge signs the session tokens with. The service refuses to start without it, and it must be the bridge's value |
| `SERVICE_ROLE_KEY` | — | **from `.env.local`**: what the session-cutoff poller reads |

`OSIONOS_APP_SESSION_SECRET` and `SERVICE_ROLE_KEY` are NOT in the compose `environment:` block
on purpose: an entry there overrides the `env_file`, and an empty default would clobber the real
secret.

## The stand-in database

grobase's Postgres is not on this Docker daemon — in link mode it runs elsewhere and is reached
through a link relay — so the dev stack brings its own small Postgres for the AI tables. On its
first start it applies three files, in this order: `infrastructure/docker/osionos/ai-db-init/00-standin.sql` (the
osionos tables the page context reads, copied from the test-only fixture of
`services/osionos-ai/scripts/test.sh`), `models/osionos-ai-migration.sql` (the real AI
tables: conversations, messages, runs, the daily spend) and `models/osionos-ai-rag-migration.sql`
(the RAG index — see "Workspace index" below).

**Those osionos tables are empty**, so the page context of a run reads nothing: every page the
client sends comes back in `run.started.skippedPageIds`, and the answer is written without any
page quoted. The real definitions are in `models/osionos-*.sql` — they are the source of truth;
the stand-in is a copy of the fixture, not a fork. Point `OSIONOS_AI_DATABASE_URL` at a real
grobase Postgres to get the real pages.

The init files run only on the FIRST start of an empty `osionos_ai_db` volume. After that,
`docker compose down -v` (which drops the volume) is the way to apply them again.

## Workspace index

The workspace index (the RAG chunks the assistant answers from) is three things in the
profile `ai`:

- `osionos-ai-db` gets the RAG migration as a third init file,
  `models/osionos-ai-rag-migration.sql` → `/docker-entrypoint-initdb.d/20-osionos-ai-rag.sql`.
  It creates `ai_chunks` (the chunks, partitioned 16 ways by workspace), `ai_index_queue`
  (the change queue) and the triggers that queue a page on write and sync its ACL
  columns. It needs only what the stand-in creates — the `osionos_pages` table and the
  three roles (`service_role`, `anon`, `authenticated`) — and creates the `vector`
  extension itself.
- `osionos-ai-embed` is the embedder: Hugging Face TEI on the CPU, serving
  `intfloat/multilingual-e5-small` (384 dims) on port 80 of the internal network. **No
  published port**: the index never leaves this host.
- `osionos-ai-indexer` is the worker: the same image as `osionos-ai`, but its entrypoint
  is `node --experimental-strip-types src/indexer/main.ts`. It embeds the queued pages
  and writes the chunks. It has no healthcheck on purpose — it serves nothing, it only
  writes to the index, and it is restarted on exit.

The service itself asks the same embedder for the query embeddings
(`OSIONOS_AI_EMBED_URL`), but does **not** wait for it: with the embedder down a run
answers without sources instead of failing.

### The model cache

The model lives in the `osionos_ai_models_tei` volume, mounted at `/data` of the embedder.
That volume keeps its exact name (like `osionos_ai_models_llm`), so it is the same cache
whatever the compose project is called. `intfloat/multilingual-e5-small` is already cached
there — the first start downloads nothing.

### An existing database does NOT get the RAG migration

The init files run only on the FIRST start of an empty `osionos_ai_db` volume. A volume
that already exists (the usual case) keeps the schema it has: the RAG migration is
**not** re-run, and the indexer then finds no `ai_chunks` table. Apply it by hand — the
file is mounted read-only in the container, so it is applied where it already sits:

```sh
docker compose --profile ai exec -T osionos-ai-db psql -U postgres -d osionos_ai -f /docker-entrypoint-initdb.d/20-osionos-ai-rag.sql
```

The migration is idempotent (`IF NOT EXISTS` everywhere, `DROP ... IF EXISTS` on the
triggers and the policies), so running it twice is harmless.

### The backfill rate

The measured backfill is **18.2 chunks/s on 8 CPUs** (query p95 9.24 ms for the same
setup) — osionos repo, branch `feat/ai-spike-gateway`,
`services/osionos-ai/spikes/local-models/RESULTS.md`. The embedder is the bottleneck and
it is CPU-bound: the rate does not grow with the number of workers, only with the CPUs
the embedder gets. A large first index therefore takes a while — scale the embedder
replicas (each with its own `cpus` share) before backfilling a big workspace, not the
indexer.

## Web search (SearXNG)

`osionos-ai-searxng` (profile `ai`) is the metasearch behind the assistant's web tools. The service
reads URLs and snippets from it; SearXNG fetches no page body and proxies no image.

- Two networks, one per direction. `osionos-ai-search-net` (`internal: true`, no egress) carries
  osionos-ai to SearXNG; only those two join it. `osionos-ai-search-egress` (plain bridge) is
  SearXNG's route to the engines; only SearXNG joins it. No published port, no other network.
- Engines: `infrastructure/searxng/settings.yml`, an allowlist (duckduckgo, wikipedia, brave, bing,
  github, stackoverflow), safe search 1, `json` format, image proxy and limiter off.
- Env: `OSIONOS_AI_WEB` (web tools; off unless exactly `on`), `OSIONOS_AI_SEARXNG_URL` (set by
  compose), `OSIONOS_AI_SEARXNG_SECRET` (optional; a dev default applies).
- Public: `OSIONOS_AI_WEB` is forced empty and SearXNG moves to `ai-dev-only`, until a
  network-isolated fetcher and an SSRF canary e2e exist.
- Gate: `sh scripts/verify/ai-searxng.sh` (rendered config and settings);
  `--live` queries a throwaway project and reports SKIP when no engine answers.

## Public mode

`docker-compose.public.yml` mounts `infrastructure/tls/public.d/ai-public.conf` into the
`:4000` vhost: 2 r/s per client, burst 10, a refused request is a 429. The bucket is per real client: the zone is keyed on the LAST entry of
`X-Forwarded-For` (`$ai_client`, `public.d/http-limits.conf`), which Funnel appends. A client
that reaches `127.0.0.1:4000` directly could forge it; only the host can.

Five AI services run on public (`osionos-ai`, `-redis`, `-embed`, `-embed-bulk`, `-indexer`); the
db, llm and stt move to the never-enabled `ai-dev-only` profile. Start them with the public
overlay and `--profile ai`, naming the five; `scripts/verify/ai-public-flags-off.sh` proves the
flags, caps, ports and DB target.
