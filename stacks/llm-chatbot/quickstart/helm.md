1. Requirements: a Kubernetes cluster with a default StorageClass, `kubectl`, `helm` 3, `openssl`. Ollama requests 4 GiB memory and a 30 GiB volume; Open WebUI 1 GiB and 5 GiB.
2. Get the files:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/llm-chatbot/helm
   ```
3. Review `values.yaml` (model list under `ollama.ollama.models.pull`, GPU under `ollama.ollama.gpu`, ingress).
4. Install (creates the namespace `llm-chatbot` and the secret `open-webui-secret`, then installs chart 17.0.0):
   ```bash
   sh install.sh
   ```
5. Open the UI:
   ```bash
   kubectl -n llm-chatbot port-forward svc/open-webui 3000:80
   ```
   Go to http://localhost:3000 and create the first account (it becomes the admin).
6. Turn off new sign-ups in Admin Panel > Settings > General.
7. Remove everything: `helm -n llm-chatbot uninstall open-webui && kubectl delete namespace llm-chatbot` (this deletes the volumes too).
