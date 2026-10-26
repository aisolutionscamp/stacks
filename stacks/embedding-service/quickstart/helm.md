## Helm (Kubernetes)

This stack ships its own small chart in `helm/chart` (there is no official TEI chart).

1. Get the stack:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/embedding-service
   ```
2. Create the namespace and a random API key:
   ```bash
   kubectl create namespace embeddings
   kubectl -n embeddings create secret generic tei-api-key \
     --from-literal=api-key="$(openssl rand -hex 32)"
   ```
3. Review `helm/values.yaml` (model, storage size, resources), then install:
   ```bash
   helm upgrade --install embeddings ./helm/chart -n embeddings -f helm/values.yaml --wait --timeout 20m
   ```
4. Test it:
   ```bash
   export API_KEY=$(kubectl -n embeddings get secret tei-api-key -o jsonpath='{.data.api-key}' | base64 -d)
   kubectl -n embeddings port-forward svc/embeddings-text-embeddings-inference 8080:80 &
   curl http://127.0.0.1:8080/embed -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $API_KEY" -d '{"inputs": "Hello world"}'
   ```
5. Remove with `helm uninstall embeddings -n embeddings` (the model cache PVC is deleted with it).
