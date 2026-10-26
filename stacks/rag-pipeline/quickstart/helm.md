## Quick start (Helm)

1. Requirements: a Kubernetes cluster (1.25 or newer) with a default StorageClass, `kubectl` and Helm 3. The default resource requests need about 5 GB of memory (Ollama 4 GB, Qdrant 512 MB, rag-api 128 MB); limits allow up to about 10 GB.
2. Get the stack files and review `helm/values.yaml` (models, volume sizes, Ingress):
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/rag-pipeline/helm
   ```
3. Install the chart (adds the chart repository, installs into the namespace `rag` and waits for rag-api):
   ```bash
   sh install.sh
   ```
4. Read the generated API key and open a tunnel:
   ```bash
   export KEY=$(kubectl -n rag get secret rag-rag-api -o jsonpath='{.data.api-key}' | base64 -d)
   kubectl -n rag port-forward svc/rag-rag-api 8000:8000
   ```
5. In a second terminal, ingest a file and ask a question:
   ```bash
   curl -s -X POST localhost:8000/ingest -H "X-API-Key: $KEY" -F files=@notes.md
   curl -s -X POST localhost:8000/query -H "X-API-Key: $KEY" \
     -H 'Content-Type: application/json' -d '{"question":"What are the notes about?"}'
   ```
6. For access from outside the cluster set `ingress.enabled=true` with a host and TLS in `values.yaml` and run `install.sh` again.
