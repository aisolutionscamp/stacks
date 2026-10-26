#!/bin/sh
# Smoke test for a running Embedding Service stack (does not start anything).
# Reads .env next to this script if present. Checks:
#   - /health and /info
#   - API key enforcement (when API_KEY is set)
#   - /embed returns vectors of the expected dimension
#   - the vectors make sense: two related sentences are closer than an unrelated one
#   - the OpenAI-compatible /v1/embeddings route returns the same dimension
#   - /rerank ranks the relevant text first (only when the reranker profile is on)
set -eu

cd "$(dirname "$0")"
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

EMBED_URL="http://127.0.0.1:${EMBED_PORT:-8080}"
RERANK_URL="http://127.0.0.1:${RERANK_PORT:-8081}"
API_KEY="${API_KEY:-}"
MODEL="${EMBED_MODEL_ID:-BAAI/bge-base-en-v1.5}"

# Known output sizes; set EXPECTED_DIM for other models.
if [ -z "${EXPECTED_DIM:-}" ]; then
  case "$MODEL" in
    BAAI/bge-small-en-v1.5 | sentence-transformers/all-MiniLM-L6-v2) EXPECTED_DIM=384 ;;
    BAAI/bge-base-en-v1.5 | nomic-ai/nomic-embed-text-v1.5) EXPECTED_DIM=768 ;;
    BAAI/bge-large-en-v1.5 | BAAI/bge-m3) EXPECTED_DIM=1024 ;;
    *) EXPECTED_DIM= ;;
  esac
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# post <url> <json>: POST with the API key (if any), print the body, fail on non-2xx.
post() {
  if [ -n "$API_KEY" ]; then
    curl -fsS --max-time 120 -H "Authorization: Bearer $API_KEY" \
      -H 'Content-Type: application/json' -d "$2" "$1"
  else
    curl -fsS --max-time 120 -H 'Content-Type: application/json' -d "$2" "$1"
  fi
}

get() {
  if [ -n "$API_KEY" ]; then
    curl -fsS --max-time 30 -H "Authorization: Bearer $API_KEY" "$1"
  else
    curl -fsS --max-time 30 "$1"
  fi
}

# One vector per line from a JSON list of lists: [[1,2],[3,4]] -> "1,2" "3,4".
split_vectors() {
  awk '{ sub(/^\[\[/, ""); sub(/\]\]$/, ""); gsub(/\],\[/, "\n"); print }'
}

# Number of comma-separated values in a flat JSON number list.
count_values() {
  tr ',' '\n' | grep -c .
}

echo "== Embeddings at $EMBED_URL (model $MODEL)"
curl -fsS --max-time 10 "$EMBED_URL/health" >/dev/null || fail "/health"
echo "ok   /health"

info=$(get "$EMBED_URL/info") || fail "/info"
echo "$info" | grep -q "\"model_id\":\"$MODEL\"" || fail "/info does not report model $MODEL: $info"
echo "ok   /info reports $MODEL"

if [ -n "$API_KEY" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H 'Content-Type: application/json' -d '{"inputs":"test"}' "$EMBED_URL/embed")
  [ "$code" = "401" ] || fail "request without API key returned $code, expected 401"
  echo "ok   request without API key is rejected (401)"
fi

# Three sentences: 1 and 2 are about the same topic, 3 is not.
out=$(post "$EMBED_URL/embed" '{"inputs":["A cat is sleeping on the sofa.","A kitten naps on the couch.","Quarterly tax filings are due in April."]}') \
  || fail "/embed request failed"
n=$(echo "$out" | split_vectors | grep -c .)
[ "$n" = "3" ] || fail "/embed returned $n vectors, expected 3"
dim=$(echo "$out" | split_vectors | head -n 1 | count_values)
if [ -n "$EXPECTED_DIM" ]; then
  [ "$dim" = "$EXPECTED_DIM" ] || fail "/embed vector has $dim dimensions, expected $EXPECTED_DIM"
else
  [ "$dim" -gt 0 ] || fail "/embed returned an empty vector"
fi
echo "ok   /embed returned 3 vectors with $dim dimensions"

sims=$(echo "$out" | split_vectors | awk -F, '
  { for (i = 1; i <= NF; i++) v[NR, i] = $i; d = NF }
  function cosine(a, b,   i, s, na, nb) {
    s = 0; na = 0; nb = 0
    for (i = 1; i <= d; i++) { s += v[a, i] * v[b, i]; na += v[a, i] ^ 2; nb += v[b, i] ^ 2 }
    return s / sqrt(na * nb)
  }
  END { printf "%.4f %.4f\n", cosine(1, 2), cosine(1, 3) }')
related=${sims% *}
unrelated=${sims#* }
awk -v r="$related" -v u="$unrelated" 'BEGIN { exit !(r > u) }' \
  || fail "related sentences ($related) are not closer than unrelated ones ($unrelated)"
echo "ok   cosine similarity: related $related > unrelated $unrelated"

oa=$(post "$EMBED_URL/v1/embeddings" "{\"model\":\"$MODEL\",\"input\":[\"Hello world\"]}") \
  || fail "/v1/embeddings request failed"
echo "$oa" | grep -q '"object":"list"' || fail "/v1/embeddings: unexpected response: $(echo "$oa" | cut -c1-200)"
oadim=$(echo "$oa" | sed 's/.*"embedding":\[\([^]]*\)\].*/\1/' | count_values)
[ "$oadim" = "$dim" ] || fail "/v1/embeddings vector has $oadim dimensions, expected $dim"
echo "ok   /v1/embeddings (OpenAI format) returned $oadim dimensions"

case ",${COMPOSE_PROFILES:-}," in
  *,reranker,*)
    echo "== Reranker at $RERANK_URL (model ${RERANK_MODEL_ID:-BAAI/bge-reranker-base})"
    curl -fsS --max-time 10 "$RERANK_URL/health" >/dev/null || fail "reranker /health"
    echo "ok   /health"
    rr=$(post "$RERANK_URL/rerank" '{"query":"Where is the cat sleeping?","texts":["Quarterly tax filings are due in April.","The cat is sleeping on the sofa."]}') \
      || fail "/rerank request failed"
    first=$(echo "$rr" | sed 's/^\[{"index":\([0-9]*\).*/\1/')
    [ "$first" = "1" ] || fail "/rerank did not rank the relevant text first: $rr"
    echo "ok   /rerank ranked the relevant text first: $rr"
    ;;
esac

echo "PASS"
