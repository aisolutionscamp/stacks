#!/bin/sh
# Smoke test for a running AI Agent Framework stack (it starts nothing).
#  1. Flowise answers /api/v1/ping
#  2. Ollama has OLLAMA_MODEL and returns a real completion
#  3. The owner account can log in, create an API key, and that key opens the Flowise API
#     (requests without a key are rejected). The test key is deleted afterwards.
# Settings come from the environment, then from .env, with the same defaults as compose.yaml.
set -eu

cd "$(dirname "$0")"
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

FLOWISE_URL="http://localhost:${FLOWISE_PORT:-3000}"
OLLAMA_URL="http://localhost:${OLLAMA_PORT:-11434}"
MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
: "${FLOWISE_ADMIN_EMAIL:?FLOWISE_ADMIN_EMAIL is not set}"
: "${FLOWISE_ADMIN_PASSWORD:?FLOWISE_ADMIN_PASSWORD is not set}"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# Escape a value for use inside a JSON string.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

echo "1/3 Flowise ping ($FLOWISE_URL)"
ping=$(curl -fsS --max-time 10 "$FLOWISE_URL/api/v1/ping") || fail "Flowise /api/v1/ping not reachable"
[ "$ping" = "pong" ] || fail "unexpected ping answer: $ping"
echo "    ok: $ping"

echo "2/3 Ollama completion with $MODEL ($OLLAMA_URL)"
if ! curl -fsS --max-time 10 "$OLLAMA_URL/api/tags" | grep -q "\"name\":\"$MODEL\""; then
  echo "    model not present yet, pulling $MODEL"
  curl -fsS --max-time 900 "$OLLAMA_URL/api/pull" -d "{\"model\":\"$MODEL\",\"stream\":false}" >/dev/null \
    || fail "could not pull $MODEL"
fi
curl -fsS --max-time 300 "$OLLAMA_URL/api/generate" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"Reply with one word: what colour is the sky on a clear day?\",\"stream\":false,\"options\":{\"num_predict\":16,\"temperature\":0}}" \
  -o "$TMP/gen.json" || fail "Ollama /api/generate failed"
answer=$(sed -n 's/.*"response":"\([^"]*\)".*/\1/p' "$TMP/gen.json")
[ -n "$answer" ] || fail "empty completion: $(cat "$TMP/gen.json")"
echo "    ok: model answered: $answer"

echo "3/3 Flowise login, API key and authenticated API call"
email=$(json_escape "$FLOWISE_ADMIN_EMAIL")
password=$(json_escape "$FLOWISE_ADMIN_PASSWORD")
# The flowise-setup container may still be creating the owner account: retry for up to 2 minutes.
i=0
while :; do
  code=$(curl -sS --max-time 20 -o "$TMP/login.json" -w '%{http_code}' -c "$TMP/cookies" \
    -H 'Content-Type: application/json' -H 'x-request-from: internal' \
    -d "{\"email\":\"$email\",\"password\":\"$password\"}" "$FLOWISE_URL/api/v1/auth/login" || echo 000)
  [ "$code" = "200" ] && break
  i=$((i + 1))
  [ "$i" -ge 24 ] && break
  sleep 5
done
[ "$code" = "200" ] || fail "login as $FLOWISE_ADMIN_EMAIL returned HTTP $code: $(cat "$TMP/login.json")"
echo "    ok: logged in as $FLOWISE_ADMIN_EMAIL"

code=$(curl -sS --max-time 20 -o "$TMP/key.json" -w '%{http_code}' -b "$TMP/cookies" \
  -H 'Content-Type: application/json' -H 'x-request-from: internal' \
  -d '{"keyName":"smoke-test","permissions":["chatflows:view"]}' "$FLOWISE_URL/api/v1/apikey")
[ "$code" = "200" ] || fail "creating an API key returned HTTP $code: $(cat "$TMP/key.json")"
# The response lists the user's keys; take the one named smoke-test.
key=$(tr '{' '\n' < "$TMP/key.json" | grep '"keyName":"smoke-test"' | sed -n 's/.*"apiKey":"\([^"]*\)".*/\1/p' | head -n 1)
key_id=$(tr '{' '\n' < "$TMP/key.json" | grep '"keyName":"smoke-test"' | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$key" ] || fail "no API key in response: $(cat "$TMP/key.json")"

code=$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' "$FLOWISE_URL/api/v1/chatflows")
[ "$code" = "401" ] || fail "API without key returned HTTP $code, expected 401"
code=$(curl -sS --max-time 20 -o "$TMP/flows.json" -w '%{http_code}' \
  -H "Authorization: Bearer $key" "$FLOWISE_URL/api/v1/chatflows")
[ "$code" = "200" ] || fail "API with key returned HTTP $code: $(cat "$TMP/flows.json")"
echo "    ok: /api/v1/chatflows returns 401 without key, 200 with key"

if [ -n "$key_id" ]; then
  curl -sS --max-time 20 -o /dev/null -X DELETE -b "$TMP/cookies" -H 'x-request-from: internal' \
    "$FLOWISE_URL/api/v1/apikey/$key_id" || true
fi

echo "Smoke test passed"
