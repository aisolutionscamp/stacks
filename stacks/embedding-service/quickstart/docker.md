## Docker Compose

1. Get the stack:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/embedding-service
   ```
2. Create the settings file and set an API key (optional, recommended):
   ```bash
   cp .env.example .env
   sed -i "s/^API_KEY=.*/API_KEY=$(openssl rand -hex 32)/" .env
   ```
   Change `EMBED_MODEL_ID` in `.env` if you want another model. Set `COMPOSE_PROFILES=reranker` to also run the reranker.
3. Start it. The first start downloads the model (about 440 MB for the default), so `--wait` can take a few minutes:
   ```bash
   docker compose up -d --wait
   ```
4. Request an embedding:
   ```bash
   export API_KEY=$(grep ^API_KEY= .env | cut -d= -f2)
   curl http://127.0.0.1:8080/embed \
     -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $API_KEY" \
     -d '{"inputs": "Hello world"}'
   ```
5. Optional: check the whole stack with `./smoke-test.sh`.
6. Stop with `docker compose down` (add `-v` to also delete the model cache).

For an NVIDIA GPU use `docker compose -f compose.yaml -f compose.gpu.yaml up -d --wait`.
