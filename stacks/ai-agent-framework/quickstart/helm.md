## Quick start (Helm)

Installs Flowise with the [HelmForge Flowise chart](https://artifacthub.io/packages/helm/helmforge/flowise) (bundled PostgreSQL) and Ollama with the [otwld Ollama chart](https://artifacthub.io/packages/helm/ollama-helm/ollama) into the namespace `ai-agents`.

1. Requirements: `kubectl` access to a cluster with a default StorageClass, Helm 3, `openssl`. Plan for about 4 CPU cores and 8 GB RAM on the nodes for the default model.
2. Get the files:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/ai-agent-framework/helm
   ```
3. Review `values.yaml` (Flowise) and `ollama-values.yaml` (model list, GPU, storage size).
4. Install. The script generates the secrets once and stores them in Kubernetes secrets:
   ```bash
   sh install.sh
   ```
5. Open Flowise:
   ```bash
   kubectl -n ai-agents port-forward svc/flowise 3000:3000
   ```
   Go to http://localhost:3000 and register the owner account immediately (in this setup the first registered user becomes the owner).
6. In flows use the Ollama base URL `http://ollama:11434`.
