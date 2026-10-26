## Terraform (Docker, one machine)

1. Get the stack:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/embedding-service/terraform/local
   ```
2. Initialize:
   ```bash
   terraform init
   ```
3. Apply. The API key is optional; leave out the variable to run without one:
   ```bash
   export API_KEY=$(openssl rand -hex 32)
   terraform apply -var "api_key=$API_KEY"
   ```
   Add `-var enable_reranker=true` for the reranker, or `-var gpu=true -var image=ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.4` for an NVIDIA GPU.
4. The container downloads the model on first start. Wait until it reports healthy:
   ```bash
   docker ps --filter name=embedding-service
   ```
5. Run the command from `terraform output test_command`.
6. Remove with `terraform destroy` (also deletes the model cache volume).
