# Embedding Service

A self-hosted HTTP API for text embeddings, built on [Hugging Face Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference) (TEI). Use it for semantic search, clustering, deduplication or as the embedding step of a RAG pipeline. An optional second service runs a reranker model.

## Architecture

| Service | Image | Port (host) | Default model | What it does |
|---|---|---|---|---|
| `embeddings` | `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4` | `127.0.0.1:8080` | `BAAI/bge-base-en-v1.5` (768 dims) | `/embed`, `/v1/embeddings` (OpenAI format), `/tokenize` |
| `reranker` (profile `reranker`, off by default) | same image | `127.0.0.1:8081` | `BAAI/bge-reranker-base` | `/rerank` |

- TEI is a Rust server. It downloads the model from Hugging Face on first start and caches it in the `models` volume (`/data` in the container). Later starts load it from the volume.
- The server only starts listening once the model is loaded, so the first start takes a while (the default model is about 440 MB). The healthcheck allows 15 minutes for this.
- Concurrent requests are batched on the server. `MAX_CLIENT_BATCH_SIZE` limits how many inputs one request may carry.
- Containers run with a read-only root filesystem, all Linux capabilities dropped and `no-new-privileges`.
- API docs (Swagger UI) are served at `/docs`.

### API examples

```bash
# TEI format: returns [[0.01, -0.03, ...]]
curl http://127.0.0.1:8080/embed \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"inputs": ["What is deep learning?", "Deep learning is a subfield of machine learning."]}'

# OpenAI format: {"object":"list","data":[{"embedding":[...],"index":0}],...}
curl http://127.0.0.1:8080/v1/embeddings \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"model": "BAAI/bge-base-en-v1.5", "input": ["What is deep learning?"]}'

# Reranker (profile reranker): returns [{"index":1,"score":0.99},{"index":0,"score":0.01}]
curl http://127.0.0.1:8081/rerank \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"query": "What is deep learning?", "texts": ["Paris is in France.", "Deep learning uses neural networks."]}'
```

Leave out the `Authorization` header if no `API_KEY` is set. OpenAI client libraries work with `base_url="http://127.0.0.1:8080/v1"` and the API key as `api_key`.

## Configuration

All settings live in `.env` (copy `.env.example`):

| Variable | Default | Meaning |
|---|---|---|
| `EMBED_MODEL_ID` | `BAAI/bge-base-en-v1.5` | Embedding model. Examples: `BAAI/bge-small-en-v1.5` (384 dims, small and fast), `BAAI/bge-large-en-v1.5` (1024 dims), `BAAI/bge-m3` (multilingual). See the [supported models](https://github.com/huggingface/text-embeddings-inference#supported-models). |
| `EMBED_MODEL_REVISION` | `main` | Branch, tag or commit hash. Pin a commit hash for reproducible results. |
| `EMBED_PORT` | `8080` | Host port, bound to `127.0.0.1`. |
| `API_KEY` | empty | When set, every route except `/health` and `/metrics` needs `Authorization: Bearer <key>`. Generate with `openssl rand -hex 32`. |
| `HF_TOKEN` | empty | Only for gated or private models. |
| `MAX_CLIENT_BATCH_SIZE` | `32` | Maximum inputs per request. |
| `AUTO_TRUNCATE` | `true` | Cut inputs that are longer than the model's maximum length instead of returning an error. |
| `COMPOSE_PROFILES` | empty | `reranker` also starts the reranker. |
| `RERANK_MODEL_ID` | `BAAI/bge-reranker-base` | Reranker model (about 1.1 GB). |
| `RERANK_MODEL_REVISION` | `main` | Reranker model revision. |
| `RERANK_PORT` | `8081` | Host port for the reranker, bound to `127.0.0.1`. |

Changing the model changes the vector size. Vectors from different models are not comparable, so re-embed your data when you switch.

### GPU

`compose.gpu.yaml` switches both services to `ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.4` and reserves one NVIDIA GPU. That image contains builds for Turing, Ampere, Ada Lovelace, Hopper and Blackwell GPUs and picks one at start. It needs the NVIDIA driver and the NVIDIA Container Toolkit on the host:

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --wait
```

TEI's own per-architecture images (for example `86-1.9.4` for A10/A40, `89-1.9.4` for Ada, `hopper-1.9.4`) are smaller; set one in `compose.gpu.yaml` if you know your GPU.

### Kubernetes

There is no official Helm chart for TEI, so this stack contains a small chart in `helm/chart` (Deployment, Service, PersistentVolumeClaim, optional HorizontalPodAutoscaler and Ingress). Pods run as a non-root user with a read-only root filesystem. The model cache uses a ReadWriteOnce volume by default, which allows one replica; to scale out, use a ReadWriteMany storage class or `persistence.enabled=false` (each pod then downloads the model). The chart refuses autoscaling with a ReadWriteOnce volume.

For a GPU node set `image.tag=cuda-1.9.4` and `resources.limits."nvidia.com/gpu"=1`. The CUDA image's entrypoint may need to run `ldconfig`; if the pod fails at start with a permission error, set `securityContext.readOnlyRootFilesystem=false`.

## Security notes

- Ports are bound to `127.0.0.1` in Compose and Terraform (Docker). To serve other machines, put a reverse proxy with TLS in front, and set `API_KEY`.
- TEI has a single shared API key and no rate limiting. `/health`, `/metrics` and `/docs` stay open without the key.
- The Helm install creates a random API key in the Secret `tei-api-key`. The AWS Terraform requires an API key, stores it in SSM Parameter Store and opens the API port only to `allowed_cidr`. Traffic is plain HTTP there; add a TLS load balancer or proxy before you send data over the internet.
- Use models from sources you trust and pin the revision, so an upstream model change cannot alter results unnoticed.

## Upgrading

1. Check the [TEI releases](https://github.com/huggingface/text-embeddings-inference/releases) for breaking changes.
2. Change the image tag in `compose.yaml` (and `compose.gpu.yaml`, `helm/values.yaml`, the Terraform files) to the new exact version, e.g. `cpu-1.9.5`.
3. `docker compose pull && docker compose up -d --wait`. The model cache volume is kept.

TEI 1.9 changed the default GeLU implementation; embeddings from older versions can differ slightly. Re-embed if you need exact consistency.

## Troubleshooting

- **`docker compose up --wait` takes long or times out**: the model is still downloading. Follow it with `docker compose logs -f embeddings`.
- **`401 Unauthorized`**: `API_KEY` is set, send `Authorization: Bearer <key>`.
- **Batch size errors**: lower the number of inputs per request or raise `MAX_CLIENT_BATCH_SIZE`. Requests larger than 2 MB are rejected (TEI `PAYLOAD_LIMIT`).
- **Input validation error about too many tokens**: the text is longer than the model accepts (512 tokens for the bge models). Set `AUTO_TRUNCATE=true` or split long texts.
- **Gated model download fails**: accept the model license on huggingface.co and set `HF_TOKEN`.
- **`exec format error`** on ARM64 (e.g. Apple Silicon, Graviton): use `ghcr.io/huggingface/text-embeddings-inference:cpu-arm64-1.9.4`.
- **Reset the model cache**: `docker compose down -v` removes the `models` volume.
