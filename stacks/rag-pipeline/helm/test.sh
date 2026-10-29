#!/bin/sh
# CI check for the Helm option, run inside alpine/helm from the stack directory:
#   docker run --rm -v "$PWD:/w" -w /w --entrypoint sh alpine/helm:3.19.0 -c 'sh helm/test.sh'
# Renders the rag-stack chart with helm/values.yaml. Uses the published chart
# when CHART_VERSION is in the chart repository; otherwise lints and renders the
# chart from the charts Git repository (main branch), which is where a new chart
# version lives until chart-releaser has published it.
# RAG_STACK_CHART_DIR=/path/to/charts/rag-stack uses a local checkout instead.
set -eu

CHART_VERSION=1.0.1
CHART_REPO=https://aisolutionscamp.github.io/charts
CHARTS_GIT=${CHARTS_GIT:-https://github.com/aisolutionscamp/charts.git}
VALUES=helm/values.yaml
OUT=$(mktemp)
trap 'rm -f "$OUT"' EXIT

check_rendered() {
  grep -q 'kind: Deployment' "$OUT"
  grep -q 'name: rag-rag-api$' "$OUT"
  grep -q 'image: "ghcr.io/aisolutionscamp/rag-api:1.0.1"' "$OUT"
  grep -q 'image: "docker.io/qdrant/qdrant:v1.20.0"' "$OUT"
  grep -q 'image: "ollama/ollama:0.40.11"' "$OUT"
  grep -q 'kind: NetworkPolicy' "$OUT"
  echo "rendered $(grep -c '^kind:' "$OUT") resources"
}

if [ -z "${RAG_STACK_CHART_DIR:-}" ] \
  && helm repo add aisolutionscamp "$CHART_REPO" >/dev/null 2>&1 \
  && helm repo update aisolutionscamp >/dev/null 2>&1 \
  && helm search repo aisolutionscamp/rag-stack --version "$CHART_VERSION" | grep -q rag-stack; then
  echo "using published chart aisolutionscamp/rag-stack $CHART_VERSION"
  helm template rag aisolutionscamp/rag-stack --version "$CHART_VERSION" -n rag -f "$VALUES" >"$OUT"
  check_rendered
  exit 0
fi

if [ -z "${RAG_STACK_CHART_DIR:-}" ]; then
  echo "rag-stack $CHART_VERSION is not published in $CHART_REPO yet; using $CHARTS_GIT (main)"
  TMPD=$(mktemp -d)
  git clone --quiet --depth 1 "$CHARTS_GIT" "$TMPD/charts"
  RAG_STACK_CHART_DIR=$TMPD/charts/charts/rag-stack
fi
CHART_DIR=$(mktemp -d)
cp -R "$RAG_STACK_CHART_DIR/." "$CHART_DIR/"
found=$(sed -n 's/^version: *//p' "$CHART_DIR/Chart.yaml" | tr -d '"')
if [ "$found" != "$CHART_VERSION" ]; then
  echo "chart version is $found, expected $CHART_VERSION" >&2
  exit 1
fi
helm repo add qdrant https://qdrant.github.io/qdrant-helm >/dev/null
helm repo add ollama https://otwld.github.io/ollama-helm >/dev/null
helm dependency build "$CHART_DIR" >/dev/null
helm lint --strict "$CHART_DIR" -f "$VALUES"
helm template rag "$CHART_DIR" -n rag -f "$VALUES" >"$OUT"
check_rendered
