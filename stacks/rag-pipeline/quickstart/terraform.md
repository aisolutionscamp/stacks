## Quick start (Terraform, Docker provider)

1. Requirements: Terraform 1.5 or newer and Docker on the target machine.
2. Get the configuration:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/rag-pipeline/terraform/local
   ```
3. Set the two keys (they are not stored in the configuration):
   ```bash
   export TF_VAR_qdrant_api_key=$(openssl rand -hex 32)
   export TF_VAR_rag_api_key=$(openssl rand -hex 32)
   ```
   Keep the values; the Terraform state also contains them, so protect the state file.
4. Create the containers. `apply` waits until rag-api has pulled the models and is healthy:
   ```bash
   terraform init
   terraform apply
   ```
   To build rag-api from source instead of pulling it: `terraform apply -var build_rag_api=true`.
5. Test it:
   ```bash
   curl -s -X POST "$(terraform output -raw rag_api_url)/query" -H "X-API-Key: $TF_VAR_rag_api_key" \
     -H 'Content-Type: application/json' -d '{"question":"Hello?"}'
   ```
6. Remove everything with `terraform destroy` (this also deletes the volumes).
