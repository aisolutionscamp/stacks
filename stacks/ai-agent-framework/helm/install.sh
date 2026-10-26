#!/bin/sh
# Installs Flowise (HelmForge chart) with PostgreSQL, and Ollama (otwld chart),
# into the namespace "ai-agents". Run from the helm/ directory.
set -eu
NS=ai-agents

helm repo add helmforge https://repo.helmforge.dev
helm repo add otwld https://otwld.github.io/ollama-helm/
helm repo update

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Secrets are generated once. Keep them: changing encryption-key makes stored
# credentials unreadable, changing the database password breaks the connection.
if ! kubectl -n "$NS" get secret flowise-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic flowise-auth \
    --from-literal=encryption-key="$(openssl rand -hex 32)" \
    --from-literal=jwt-auth-token-secret="$(openssl rand -hex 32)" \
    --from-literal=jwt-refresh-token-secret="$(openssl rand -hex 32)" \
    --from-literal=express-session-secret="$(openssl rand -hex 32)" \
    --from-literal=token-hash-secret="$(openssl rand -hex 32)"
fi
if ! kubectl -n "$NS" get secret flowise-postgresql-auth >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic flowise-postgresql-auth \
    --from-literal=postgres-password="$(openssl rand -hex 32)" \
    --from-literal=user-password="$(openssl rand -hex 32)" \
    --from-literal=replication-password="$(openssl rand -hex 32)"
fi

helm upgrade --install ollama otwld/ollama --version 1.92.0 \
  --namespace "$NS" -f ollama-values.yaml

helm upgrade --install flowise helmforge/flowise --version 1.3.13 \
  --namespace "$NS" -f values.yaml

kubectl -n "$NS" rollout status deployment/flowise --timeout=10m
echo "Open Flowise: kubectl -n $NS port-forward svc/flowise 3000:3000, then http://localhost:3000"
echo "Create the owner account right away. In Flowise use the Ollama base URL http://ollama:11434"
