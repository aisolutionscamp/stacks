1. Requirements: Docker and Terraform 1.5 or newer on the same machine.
2. Get the files:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/llm-chatbot/terraform/local
   ```
3. Set the secret key:
   ```bash
   export TF_VAR_webui_secret_key="$(openssl rand -hex 32)"
   ```
   Optional: `export TF_VAR_default_model=qwen2.5:0.5b` for a smaller model.
4. Deploy (pulls the images and the model, waits until Open WebUI is healthy):
   ```bash
   terraform init
   terraform apply
   ```
5. Open the URL from `terraform output open_webui_url` (http://localhost:3000) and create the first account (it becomes the admin).
6. Turn off new sign-ups in Admin Panel > Settings > General.
7. Remove: `terraform destroy` (deletes the containers and the volumes with chats and models).
