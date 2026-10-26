#!/bin/sh
# Hugging Face Text Embeddings Inference on Kubernetes.
# There is no official Helm chart for TEI, so this stack ships a small chart
# in helm/chart. Run from a checkout of the stacks repository.
set -eu

git clone https://github.com/aisolutionscamp/stacks.git
cd stacks/stacks/embedding-service

kubectl create namespace embeddings

# API key for the service (stored only in the cluster).
kubectl -n embeddings create secret generic tei-api-key \
  --from-literal=api-key="$(openssl rand -hex 32)"

helm upgrade --install embeddings ./helm/chart \
  --namespace embeddings \
  -f helm/values.yaml \
  --wait --timeout 20m

# Read the key back when you need it:
#   kubectl -n embeddings get secret tei-api-key -o jsonpath='{.data.api-key}' | base64 -d
