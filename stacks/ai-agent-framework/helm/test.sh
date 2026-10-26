#!/bin/sh
# CI check (runs in alpine/helm:3.19.0 from the stack directory): renders both
# charts with the values files and fails on errors.
set -eu
helm repo add helmforge https://repo.helmforge.dev >/dev/null
helm repo add otwld https://otwld.github.io/ollama-helm/ >/dev/null
helm repo update >/dev/null

out=$(mktemp)
helm template flowise helmforge/flowise --version 1.3.13 --namespace ai-agents -f helm/values.yaml > "$out"
grep -q 'image: "docker.io/flowiseai/flowise:3.1.4"' "$out" || { echo "flowise image tag not applied"; exit 1; }
grep -q 'name: flowise-auth' "$out" || { echo "flowise-auth secret not referenced"; exit 1; }
grep -q 'mountPath: /home/node/.flowise' "$out" || { echo "data volume not mounted"; exit 1; }
if grep -q 'kind: Secret' "$out"; then echo "chart generated its own secret, expected existing secrets"; exit 1; fi
echo "flowise: rendered $(grep -c '^kind:' "$out") objects"

helm template ollama otwld/ollama --version 1.92.0 --namespace ai-agents -f helm/ollama-values.yaml > "$out"
grep -q 'ollama/ollama:0.40.11' "$out" || { echo "ollama image tag not applied"; exit 1; }
echo "ollama: rendered $(grep -c '^kind:' "$out") objects"
rm -f "$out"
