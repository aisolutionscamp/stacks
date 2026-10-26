## Quick start (Docker Compose)

1. Get the stack:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/rag-pipeline
   ```
2. Create `.env` with two generated keys:
   ```bash
   cp .env.example .env
   sed -i "s/^QDRANT_API_KEY=.*/QDRANT_API_KEY=$(openssl rand -hex 32)/" .env
   sed -i "s/^RAG_API_KEY=.*/RAG_API_KEY=$(openssl rand -hex 32)/" .env
   ```
3. Start it. The first start downloads about 6 GB (images and models) and can take several minutes:
   ```bash
   docker compose up -d --build --wait
   ```
   With an NVIDIA GPU: `docker compose -f compose.yaml -f compose.gpu.yaml up -d --build --wait`.
4. Add a document and ask a question:
   ```bash
   KEY=$(grep ^RAG_API_KEY= .env | cut -d= -f2)
   curl -s -X POST localhost:8000/ingest -H "X-API-Key: $KEY" -F files=@README.md
   curl -s -X POST localhost:8000/query -H "X-API-Key: $KEY" \
     -H 'Content-Type: application/json' -d '{"question":"Which services does the stack run?"}'
   ```
5. Optional: check the whole stack with `./smoke-test.sh`. Stop it with `docker compose down` (add `-v` to delete documents and models).
