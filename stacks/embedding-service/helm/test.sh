#!/bin/sh
# Run by CI from the stack directory inside alpine/helm:3.19.0.
set -eu

helm lint ./helm/chart -f helm/values.yaml --strict
helm template embeddings ./helm/chart -n embeddings -f helm/values.yaml >/dev/null

# Optional features render too.
helm template embeddings ./helm/chart -n embeddings -f helm/values.yaml \
  --set persistence.enabled=false --set autoscaling.enabled=true \
  --set ingress.enabled=true --set hfToken.existingSecret=hf-token >/dev/null

# ReadWriteOnce cache with autoscaling must be refused.
if helm template embeddings ./helm/chart -f helm/values.yaml \
  --set autoscaling.enabled=true >/dev/null 2>&1; then
  echo "expected the chart to refuse autoscaling with a ReadWriteOnce volume" >&2
  exit 1
fi

echo "helm checks passed"
