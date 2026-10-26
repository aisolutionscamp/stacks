## Architecture

Three containers on one Docker network:

| Service | Image | Port (host) | Purpose |
|---|---|---|---|
| `open-webui` | `ghcr.io/open-webui/open-webui:0.12.4` | `127.0.0.1:3000` -> 8080 | Chat UI, user accounts, chat history (SQLite in the `open-webui-data` volume) |
| `ollama` | `ollama/ollama:0.40.11` | `127.0.0.1:11434` -> 11434 | Runs the models; stores them in the `ollama-data` volume |
| `model-pull` | `ollama/ollama:0.40.11` | none | One-shot job: pulls `DEFAULT_MODEL` into Ollama, then exits |

Open WebUI talks to Ollama over the internal network (`http://ollama:11434`). Both ports are bound to `127.0.0.1`, so nothing is reachable from other machines until you put a reverse proxy with TLS in front of Open WebUI. Ollama's API has no authentication; do not publish it.

The default model is `llama3.2` (Meta Llama 3.2 3B, about 2 GB download). Other models can be pulled from the Open WebUI admin panel (Admin Panel > Settings > Models) or with `docker compose exec ollama ollama pull <model>`. Model names are listed at https://ollama.com/library.

## Requirements

- Docker Engine with the Compose plugin (`docker compose`)
- CPU only: 8 GB RAM is enough for 1B-3B models such as `llama3.2`; 7B-8B models need about 16 GB. Answers on CPU take seconds to tens of seconds.
- Disk: about 15 GB for the two images (Ollama 8.4 GB, Open WebUI 6.4 GB unpacked) plus the models (`llama3.2` about 2 GB, `llama3.1:8b` about 4.9 GB)
- Optional: NVIDIA GPU with the NVIDIA Container Toolkit (`compose.gpu.yaml`)

## Configuration

All settings are in `.env` (copy from `.env.example`). Required:

- `WEBUI_SECRET_KEY`: signs login sessions. Generate with `openssl rand -hex 32`. Compose refuses to start without it. Keep it stable; changing it logs everyone out.

Common optional settings: `DEFAULT_MODEL` (empty skips the download), `WEBUI_PORT`, `OLLAMA_PORT`, `WEBUI_URL` (set to the public URL when you use a domain), `ENABLE_OPENAI_API` (set to `true` to add OpenAI-compatible APIs in the admin panel), `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_PARALLEL`, `OLLAMA_MAX_LOADED_MODELS`.

GPU (NVIDIA):

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --wait
```

## Accounts and sign-up

- The **first account** you create on the sign-up page becomes the **admin**. Create it right after the first start, before anyone else can reach the page.
- Later sign-ups get the role `pending` (`DEFAULT_USER_ROLE`) and can only use the UI after an admin approves them.
- After creating your admin account, turn sign-up off in Admin Panel > Settings > General ("Enable New Sign Ups"), and add users yourself in Admin Panel > Users.
- Open WebUI saves settings such as `ENABLE_SIGNUP`, `DEFAULT_USER_ROLE` and `DEFAULT_MODELS` in its database on the first start. Changing these variables later has no effect; change them in the admin panel instead.

## Security notes

- No default passwords or keys. `WEBUI_SECRET_KEY` must be set.
- Ports are bound to `127.0.0.1`. For access from other machines, use a reverse proxy with TLS (Caddy, Traefik, nginx) in front of port 3000 and set `WEBUI_URL`.
- Do not expose port 11434. Anyone who reaches Ollama can run, pull and delete models.
- The OpenAI API connection is off by default (`ENABLE_OPENAI_API=false`), so no request leaves the machine except model and image downloads.
- Back up the `open-webui-data` volume: it holds accounts and chats.

## Upgrading

1. Read the release notes of [Open WebUI](https://github.com/open-webui/open-webui/releases) and [Ollama](https://github.com/ollama/ollama/releases).
2. Back up the data volume, for example:
   `docker run --rm -v llm-chatbot_open-webui-data:/data -v "$PWD":/backup alpine tar czf /backup/open-webui-data.tgz -C /data .`
3. Change `OPEN_WEBUI_VERSION` / `OLLAMA_VERSION` in `.env`.
4. `docker compose pull && docker compose up -d --wait`. Open WebUI runs its database migrations on start.

## Testing

`smoke-test.sh` checks a running stack: Ollama API, model pull, a real completion from Ollama, and Open WebUI `/health`, the UI and `/api/config`. With `SMOKE_WEBUI_SIGNUP=true` (only on an empty test instance, as in CI) it also creates an account and gets a chat completion through Open WebUI.

```bash
./smoke-test.sh
```

## Troubleshooting

- `required variable WEBUI_SECRET_KEY is missing`: set it in `.env` (`openssl rand -hex 32`).
- `open-webui` is "starting" for a few minutes on the first run: it downloads the embedding model used for document chat and runs migrations. `docker compose logs -f open-webui` shows progress.
- No models in the model list: check `docker compose logs model-pull`, or pull one with `docker compose exec ollama ollama pull llama3.2`.
- Very slow answers: the model runs on CPU. Use a smaller model, or the GPU override.
- Out of memory / Ollama restarts: choose a smaller model, or lower `OLLAMA_NUM_PARALLEL` and `OLLAMA_MAX_LOADED_MODELS`.
- Lost the admin password: see the Open WebUI docs on resetting the admin password (it is stored in `webui.db` in the `open-webui-data` volume).

## Other deployment options

- **Kubernetes (Helm):** `helm/install.sh` installs the official Open WebUI chart (17.0.0) with its bundled Ollama subchart; settings in `helm/values.yaml`.
- **Terraform (Docker):** `terraform/local/main.tf` runs the same containers on one machine with the `kreuzwerker/docker` provider.
- **Terraform (AWS):** `terraform/aws/main.tf` starts one EC2 instance (optional GPU) that runs this compose stack; access is limited to `allowed_cidr`, administration through SSM Session Manager.
