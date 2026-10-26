## Quick start (Terraform, Docker provider)

Runs the same containers as Docker Compose on the machine where Docker runs.

1. Get the files:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/ai-agent-framework/terraform/local
   ```
2. Set the owner account and the secrets:
   ```bash
   export TF_VAR_flowise_admin_email="you@example.com"
   export TF_VAR_flowise_admin_password="Fw-7$(openssl rand -hex 12)"; echo "$TF_VAR_flowise_admin_password"
   for v in postgres_password flowise_secretkey_overwrite jwt_auth_token_secret \
     jwt_refresh_token_secret express_session_secret token_hash_secret; do
     export "TF_VAR_$v=$(openssl rand -hex 32)"
   done
   ```
   Save these values somewhere safe: Terraform needs the same ones on every later `apply`.
3. Deploy:
   ```bash
   terraform init
   terraform apply
   ```
   `apply` waits until the model is pulled and the owner account exists.
4. Open the `flowise_url` output (http://localhost:3000) and log in.
5. In flows use the Ollama base URL `http://ollama:11434`.
