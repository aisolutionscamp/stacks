#!/bin/sh
# Installs Open WebUI with the bundled Ollama subchart into the namespace llm-chatbot.
set -eu

NAMESPACE=llm-chatbot

helm repo add open-webui https://helm.openwebui.com
helm repo update open-webui

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Session signing key. Created once; keep it stable (changing it logs out every user).
kubectl -n "$NAMESPACE" get secret open-webui-secret >/dev/null 2>&1 || \
  kubectl -n "$NAMESPACE" create secret generic open-webui-secret \
    --from-literal=webui-secret-key="$(openssl rand -hex 32)"

helm upgrade --install open-webui open-webui/open-webui \
  --version 17.0.0 \
  --namespace "$NAMESPACE" \
  -f values.yaml \
  --wait --timeout 15m

# Open the UI on http://localhost:3000 :
#   kubectl -n llm-chatbot port-forward svc/open-webui 3000:80
