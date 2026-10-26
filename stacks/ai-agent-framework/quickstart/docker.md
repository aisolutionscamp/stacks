## Quick start (Docker Compose)

1. Get the files and create your settings:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/ai-agent-framework
   cp .env.example .env
   ```
2. Fill in `.env`: set `FLOWISE_ADMIN_EMAIL` and `FLOWISE_ADMIN_PASSWORD` (8+ characters with upper and lower case, a digit and a special character), and generate every secret with `openssl rand -hex 32`:
   `FLOWISE_SECRETKEY_OVERWRITE`, `JWT_AUTH_TOKEN_SECRET`, `JWT_REFRESH_TOKEN_SECRET`, `EXPRESS_SESSION_SECRET`, `TOKEN_HASH_SECRET`, `POSTGRES_PASSWORD`.
3. Start the stack:
   ```bash
   docker compose up -d --wait
   ```
   The owner account is created automatically. The model (`llama3.2:3b`, about 2 GB) keeps downloading in the background: `docker compose logs -f ollama-pull`.
4. Open http://localhost:3000 and log in with the email and password from `.env`.
5. Build an agent: **Agentflows** > **Add New**, add an Agent node, choose **ChatOllama** with base URL `http://ollama:11434` and model `llama3.2:3b`, then add tools.
6. Optional check: `./smoke-test.sh`.
