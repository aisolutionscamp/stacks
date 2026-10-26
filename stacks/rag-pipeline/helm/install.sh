#!/bin/sh
# Install the RAG Pipeline (Qdrant + Ollama + rag-api) with the rag-stack chart.
# Chart source: https://github.com/aisolutionscamp/charts/tree/main/charts/rag-stack
set -eu

helm repo add aisolutionscamp https://aisolutionscamp.github.io/charts
helm repo update aisolutionscamp

helm upgrade --install rag aisolutionscamp/rag-stack \
  --version 1.0.0 \
  --namespace rag --create-namespace \
  -f values.yaml

# Wait until rag-api is ready (the first start pulls the models, this can take a while).
kubectl -n rag rollout status deploy/rag-rag-api --timeout=30m

# API key (generated on install):
#   kubectl -n rag get secret rag-rag-api -o jsonpath='{.data.api-key}' | base64 -d
