1. Get the stack and create your settings:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/llm-chatbot
   cp .env.example .env
   ```
2. Set the secret key in `.env`:
   ```bash
   sed -i "s/^WEBUI_SECRET_KEY=.*/WEBUI_SECRET_KEY=$(openssl rand -hex 32)/" .env
   ```
   Optional: change `DEFAULT_MODEL` (default `llama3.2`, about 2 GB).
3. Start the stack (the first start downloads the images and the model):
   ```bash
   docker compose up -d --wait
   ```
   With an NVIDIA GPU: `docker compose -f compose.yaml -f compose.gpu.yaml up -d --wait`
4. Check that it works:
   ```bash
   ./smoke-test.sh
   ```
5. Open http://localhost:3000 and create an account. The first account becomes the admin.
6. Turn off new sign-ups: Admin Panel > Settings > General > "Enable New Sign Ups".
7. Pull more models in Admin Panel > Settings > Models, or:
   ```bash
   docker compose exec ollama ollama pull llama3.1:8b
   ```
