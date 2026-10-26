#!/bin/sh
# Smoke test for a running RAG Pipeline stack (does not start anything).
# Checks: health, API key enforcement, Qdrant auth, JSON and file ingest,
# retrieval of the right source, an answer from the chat model, delete.
# Settings come from the environment, then from .env, then compose defaults.
set -eu

cd "$(dirname "$0")"

from_env_file() {
  # Prints the value of $1 from .env without executing the file.
  [ -f .env ] || return 0
  sed -n "s/^$1=//p" .env | tail -n 1
}
setting() {
  eval "val=\${$1:-}"
  [ -n "$val" ] || val=$(from_env_file "$1")
  [ -n "$val" ] || val=$2
  printf '%s' "$val"
}

API_PORT=$(setting RAG_API_PORT 8000)
QDRANT_PORT=$(setting QDRANT_PORT 6333)
API_KEY=$(setting RAG_API_KEY "")
QDRANT_KEY=$(setting QDRANT_API_KEY "")
API="http://127.0.0.1:${API_PORT}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

auth() {
  # curl with the API key header, if one is configured.
  if [ -n "$API_KEY" ]; then curl -sS -H "X-API-Key: ${API_KEY}" "$@"; else curl -sS "$@"; fi
}

# 1. Health (models pulled, collection ready).
i=0
until curl -fsS "$API/health" >"$TMP/health" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 60 ] || fail "rag-api /health not ready: $(curl -sS "$API/health" || true)"
  sleep 5
done
grep -q '"status":"ok"' "$TMP/health" || fail "unexpected health: $(cat "$TMP/health")"
ok "health $(cat "$TMP/health")"

# 2. Auth: rag-api rejects requests without the key; Qdrant rejects requests without its key.
if [ -n "$API_KEY" ]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API/query" \
    -H 'Content-Type: application/json' -d '{"question":"test"}')
  [ "$code" = "401" ] || fail "rag-api without API key returned $code, expected 401"
  ok "rag-api requires the API key (401 without it)"
fi
code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${QDRANT_PORT}/collections")
[ "$code" = "401" ] || [ "$code" = "403" ] || fail "Qdrant without API key returned $code, expected 401/403"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "api-key: ${QDRANT_KEY}" "http://127.0.0.1:${QDRANT_PORT}/collections")
[ "$code" = "200" ] || fail "Qdrant with API key returned $code"
ok "Qdrant requires its API key"

# 3. Ingest JSON text plus a Markdown file upload.
cat >"$TMP/payload.json" <<'EOF'
{"documents": [
  {"source": "smoke-lighthouse.txt",
   "text": "The Marlow Point lighthouse was painted green in 1931. Its keeper was named Edda Vossberg. The light can be seen from 22 nautical miles away.",
   "metadata": {"test": true}},
  {"source": "smoke-bakery.txt",
   "text": "The bakery on Linden Street opens at six in the morning and sells rye bread, pretzels and apple cake."}
]}
EOF
auth -f -X POST "$API/ingest" -H 'Content-Type: application/json' --data-binary "@$TMP/payload.json" >"$TMP/ingest" \
  || fail "JSON ingest failed"
grep -q '"source":"smoke-lighthouse.txt","chunks":1' "$TMP/ingest" || fail "unexpected ingest result: $(cat "$TMP/ingest")"
ok "JSON ingest $(cat "$TMP/ingest")"

printf '# Garden notes\n\nThe greenhouse tomatoes are watered every Tuesday with rain water.\n' >"$TMP/smoke-garden.md"
auth -f -X POST "$API/ingest" -F "files=@$TMP/smoke-garden.md" >"$TMP/ingest2" || fail "file ingest failed"
grep -q '"source":"smoke-garden.md"' "$TMP/ingest2" || fail "unexpected file ingest result: $(cat "$TMP/ingest2")"
ok "file ingest $(cat "$TMP/ingest2")"

# 4. Query: the top source must be the lighthouse document, the answer must name the keeper.
auth -f -X POST "$API/query" -H 'Content-Type: application/json' \
  -d '{"question":"What was the name of the keeper of the Marlow Point lighthouse?","top_k":2}' >"$TMP/query" \
  || fail "query failed"
grep -q '"sources":\[{"n":1,"source":"smoke-lighthouse.txt"' "$TMP/query" || fail "wrong top source: $(cat "$TMP/query")"
answer=$(sed -n 's/.*"answer":"\([^"]*\)".*/\1/p' "$TMP/query")
[ -n "$answer" ] || fail "empty answer: $(cat "$TMP/query")"
grep -o '"answer":"[^"]*"' "$TMP/query" | grep -qi 'vossberg' || fail "answer does not name the keeper: $answer"
ok "query answer: $answer"

# 5. Delete the test documents and confirm they are gone.
for s in smoke-lighthouse.txt smoke-bakery.txt smoke-garden.md; do
  auth -f -X DELETE "$API/documents?source=$s" >/dev/null || fail "delete $s failed"
done
auth -f -X POST "$API/query" -H 'Content-Type: application/json' \
  -d '{"question":"lighthouse keeper","source":"smoke-lighthouse.txt"}' >"$TMP/query2" || fail "query after delete failed"
grep -q '"sources":\[\]' "$TMP/query2" || fail "documents still present after delete: $(cat "$TMP/query2")"
ok "delete"

echo "smoke test passed"
