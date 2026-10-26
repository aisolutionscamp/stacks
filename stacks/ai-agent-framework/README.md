# AI Agent Framework (Flowise + Ollama + PostgreSQL)

A self-hosted visual builder for LLM agents. You build chatflows and agentflows in [Flowise](https://github.com/FlowiseAI/Flowise), run local models with [Ollama](https://ollama.com), and keep all Flowise data in PostgreSQL.

## Architecture

| Service | Image | Port | Purpose |
|---|---|---|---|
| `flowise` | `flowiseai/flowise:3.1.4` | `127.0.0.1:3000` (`FLOWISE_PORT`) | Web UI, REST API (`/api/v1/...`), flow execution |
| `postgres` | `postgres:17.11-alpine` | not published | Flowise database (flows, users, API keys, chat history, encrypted credentials) |
| `ollama` | `ollama/ollama:0.40.11` | `127.0.0.1:11434` (`OLLAMA_PORT`) | Local model server, reachable from Flowise as `http://ollama:11434` |
| `ollama-pull` | `ollama/ollama:0.40.11` | none | One-shot: pulls `OLLAMA_MODEL` (default `llama3.2:3b`), then exits |
| `flowise-setup` | `flowiseai/flowise:3.1.4` | none | One-shot: creates the owner account from `FLOWISE_ADMIN_EMAIL` / `FLOWISE_ADMIN_PASSWORD`, then exits |

Volumes: `postgres_data`, `ollama_data` (models), `flowise_data` (uploaded files, logs). The Flowise image runs as the non-root user `node` (uid 1000); its volume is mounted at `/home/node` so it is writable.

## Configuration

All settings are in `.env` (copy from `.env.example`). Required before the first start:

- `FLOWISE_ADMIN_EMAIL`, `FLOWISE_ADMIN_PASSWORD`: the owner account. Flowise requires 8 to 128 characters with lower case, upper case, a digit and a special character.
- `FLOWISE_SECRETKEY_OVERWRITE`: encryption key for credentials stored in Flowise (API keys of model providers and tools).
- `JWT_AUTH_TOKEN_SECRET`, `JWT_REFRESH_TOKEN_SECRET`, `EXPRESS_SESSION_SECRET`, `TOKEN_HASH_SECRET`: login token and session secrets.
- `POSTGRES_PASSWORD`: database password.

Generate each secret with `openssl rand -hex 32`. Compose refuses to start while one of them is missing.

Optional: `OLLAMA_MODEL` (agents need a model with tool calling, for example `llama3.2:3b`, `qwen3:4b` or `qwen2.5:7b`), `APP_URL`, `LOG_LEVEL`, `DISABLE_FLOWISE_TELEMETRY`, `OLLAMA_KEEP_ALIVE`, the two ports.

### Using Ollama in a flow

In Flowise add a **ChatOllama** node (or the Ollama model in an Agent node) with base URL `http://ollama:11434` and the model name from `OLLAMA_MODEL`. Pull more models with:

```bash
docker compose exec ollama ollama pull qwen3:4b
```

### Using the API

Create an API key in the Flowise UI (**API Keys**). Call a flow with:

```bash
curl http://localhost:3000/api/v1/prediction/<chatflow-id> \
  -H "Authorization: Bearer <api-key>" -H "Content-Type: application/json" \
  -d '{"question": "Hello"}'
```

### GPU

`compose.gpu.yaml` gives Ollama access to NVIDIA GPUs (needs the NVIDIA Container Toolkit):

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --wait
```

## Security notes

- Flowise 3 has its own user accounts. The old `FLOWISE_USERNAME` / `FLOWISE_PASSWORD` basic auth is no longer used. In the open-source edition the first registered user becomes the owner, and registration closes after that. `flowise-setup` registers the owner from `.env` on the first start, so nobody else can claim a fresh instance. Change the password later in the UI; changing `FLOWISE_ADMIN_PASSWORD` in `.env` does not update an existing account. The Helm install has no setup job: register the owner right after the install, through `kubectl port-forward`, before you add an ingress.
- Keep `FLOWISE_SECRETKEY_OVERWRITE` stable and backed up. With a different key, stored credentials cannot be decrypted.
- Both published ports are bound to `127.0.0.1`. To expose Flowise, put a reverse proxy with TLS in front, set `APP_URL` to the `https://` URL (this turns on secure cookies), and keep Ollama private: its API has no authentication.
- Flows can run custom JavaScript functions and call external URLs. Give accounts only to people you trust with code execution on the server.
- PostgreSQL is not published on the host. Back it up with `docker compose exec postgres pg_dump -U flowise flowise > flowise.sql`.

## Upgrading

1. Read the [Flowise release notes](https://github.com/FlowiseAI/Flowise/releases) and the [Ollama releases](https://github.com/ollama/ollama/releases).
2. Back up the database (see above).
3. Change the image tags in `compose.yaml` and run `docker compose pull && docker compose up -d --wait`. Flowise runs its database migrations on start.

## Troubleshooting

- `required variable ... is missing a value`: a secret in `.env` is empty.
- `docker compose logs flowise-setup` shows `Invalid password`: the owner password does not meet the Flowise rules. Fix it in `.env` and run `docker compose up flowise-setup`.
- Login fails although the password is right: the owner account already existed with another password (for example from an earlier volume). Reset with `docker compose down -v` (deletes all data) or use the password set earlier.
- Model answers are slow: on CPU a 3B model needs several seconds per answer. Use a GPU or a smaller model.
- `ollama-pull` is still running after `up --wait`: the model download continues in the background; check with `docker compose logs -f ollama-pull`.
- Check the stack: `./smoke-test.sh` pings Flowise, gets a completion from Ollama, logs in, creates a temporary API key and calls the API with it.
