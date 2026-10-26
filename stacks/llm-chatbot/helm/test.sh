#!/bin/sh
# CI check (runs in alpine/helm:3.19.0 from the stack directory): renders the chart with values.yaml.
set -eu

helm repo add open-webui https://helm.openwebui.com >/dev/null
helm repo update open-webui >/dev/null

out=$(mktemp)
helm template open-webui open-webui/open-webui \
  --version 17.0.0 \
  --namespace llm-chatbot \
  -f helm/values.yaml > "$out"

# The pinned images and the secret reference must end up in the manifests.
grep -Eq 'image: "?ghcr.io/open-webui/open-webui:0.12.4' "$out" || { echo "Open WebUI image tag not applied"; exit 1; }
grep -Eq 'image: "?ollama/ollama:0.40.11' "$out" || { echo "Ollama image tag not applied"; exit 1; }
grep -q 'name: open-webui-secret' "$out" || { echo "WEBUI_SECRET_KEY secret reference missing"; exit 1; }
if grep -q 'pipelines' "$out"; then echo "Pipelines should be disabled"; exit 1; fi

echo "helm template ok ($(grep -c '^kind:' "$out") resources)"
rm -f "$out"
