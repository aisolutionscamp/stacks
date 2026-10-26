#!/bin/sh
# Checks a running LLM Chatbot stack end to end. Starts nothing.
#   ./smoke-test.sh            (reads .env in this directory if present)
# 1. Ollama API answers
# 2. A small test model is pulled (SMOKE_MODEL, default: DEFAULT_MODEL, then qwen2.5:0.5b)
# 3. Ollama returns a real completion for a prompt
# 4. Open WebUI /health reports status true and the UI is served
# 5. Only if SMOKE_WEBUI_SIGNUP=true (CI, empty volumes): creates an account, which becomes the
#    admin, and gets a chat completion through Open WebUI. Do not enable it on a real instance.
set -eu

cd "$(dirname "$0")"
if [ -f .env ]; then
  # Only the variables this script uses; avoids sourcing arbitrary shell.
  for v in OLLAMA_PORT WEBUI_PORT DEFAULT_MODEL SMOKE_WEBUI_SIGNUP; do
    line=$(grep -E "^${v}=" .env | tail -n 1 || true)
    if [ -n "$line" ] && eval "[ -z \"\${$v:-}\" ]"; then export "$line"; fi
  done
fi

OLLAMA_URL="http://127.0.0.1:${OLLAMA_PORT:-11434}"
WEBUI_URL="http://127.0.0.1:${WEBUI_PORT:-3000}"
MODEL="${SMOKE_MODEL:-${DEFAULT_MODEL:-}}"
[ -n "$MODEL" ] || MODEL="qwen2.5:0.5b"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "1/4 Ollama API at $OLLAMA_URL"
version=$(curl -fsS --max-time 10 "$OLLAMA_URL/api/version") || fail "Ollama API not reachable"
echo "    $version"

echo "2/4 Pull $MODEL (no-op if model-pull already fetched it)"
curl -fsS --max-time 900 "$OLLAMA_URL/api/pull" \
  -d "{\"model\":\"$MODEL\",\"stream\":false}" | grep -q '"status":"success"' \
  || fail "could not pull $MODEL"
curl -fsS --max-time 10 "$OLLAMA_URL/api/tags" | grep -q "\"name\":\"$MODEL" \
  || fail "$MODEL not listed in /api/tags"
echo "    ok"

echo "3/4 Completion from $MODEL"
resp=$(curl -fsS --max-time 300 "$OLLAMA_URL/api/generate" \
  -d "{\"model\":\"$MODEL\",\"prompt\":\"What is the capital of France? Answer in one word.\",\"stream\":false,\"options\":{\"temperature\":0,\"num_predict\":16}}") \
  || fail "generate request failed"
echo "$resp" | grep -q '"done":true' || fail "completion not finished: $resp"
answer=$(echo "$resp" | sed -n 's/.*"response":"\([^"]*\)".*/\1/p')
[ -n "$answer" ] || fail "empty completion: $resp"
echo "    answer: $answer"
echo "$answer" | grep -qi "paris" || echo "    note: answer does not mention Paris (small model), but a completion was returned"

echo "4/4 Open WebUI at $WEBUI_URL"
health=$(curl -fsS --max-time 10 "$WEBUI_URL/health") || fail "Open WebUI /health not reachable"
echo "$health" | grep -q '"status":true' || fail "Open WebUI unhealthy: $health"
echo "    /health: $health"
curl -fsS --max-time 10 "$WEBUI_URL/" | grep -qi "<html" || fail "Open WebUI did not serve the UI"
config=$(curl -fsS --max-time 10 "$WEBUI_URL/api/config") || fail "/api/config not reachable"
echo "$config" | grep -q '"version"' || fail "unexpected /api/config: $config"
echo "    UI and /api/config ok"

if [ "${SMOKE_WEBUI_SIGNUP:-false}" = "true" ]; then
  echo "5 (optional) Chat completion through Open WebUI"
  pw=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  signup=$(curl -fsS --max-time 30 "$WEBUI_URL/api/v1/auths/signup" -H 'Content-Type: application/json' \
    -d "{\"name\":\"Smoke Test\",\"email\":\"smoke@example.com\",\"password\":\"$pw\"}") \
    || fail "signup failed (is this a fresh instance?)"
  token=$(echo "$signup" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$token" ] || fail "no token in signup response"
  curl -fsS --max-time 30 "$WEBUI_URL/api/models" -H "Authorization: Bearer $token" | grep -q "\"id\":\"$MODEL" \
    || fail "Open WebUI does not list $MODEL from Ollama"
  chat=$(curl -fsS --max-time 300 "$WEBUI_URL/api/chat/completions" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}]}") \
    || fail "chat completion through Open WebUI failed"
  echo "$chat" | grep -q '"content":"[^"]' || fail "empty chat completion: $chat"
  echo "    reply: $(echo "$chat" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')"
fi

echo "PASS: LLM Chatbot stack works"
