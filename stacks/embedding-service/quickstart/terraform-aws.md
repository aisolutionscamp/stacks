## Terraform (AWS)

Creates one EC2 instance (default `c7i.xlarge`, or `g5.xlarge` with `gpu=true`) that runs the stack with Docker Compose. This creates billable resources; run `terraform plan` first.

1. Get the stack and configure AWS credentials (`aws configure` or environment variables):
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/embedding-service/terraform/aws
   ```
2. Initialize:
   ```bash
   terraform init
   ```
3. Apply with your own IP range and a new API key:
   ```bash
   export API_KEY=$(openssl rand -hex 32)
   terraform apply -var "allowed_cidr=$(curl -s https://checkip.amazonaws.com)/32" -var "api_key=$API_KEY"
   ```
   Optional: `-var gpu=true`, `-var enable_reranker=true`, `-var region=us-east-1`.
4. Boot, image pull and model download take several minutes. Then:
   ```bash
   curl "$(terraform output -raw embeddings_url)/embed" -H 'Content-Type: application/json' \
     -H "Authorization: Bearer $API_KEY" -d '{"inputs": "Hello world"}'
   ```
5. For a shell on the instance: `aws ssm start-session --target "$(terraform output -raw instance_id)"`. Setup logs are in `/var/log/cloud-init-output.log`.
6. Remove everything with `terraform destroy`.

The API is plain HTTP and only reachable from `allowed_cidr`. Add a TLS load balancer or reverse proxy before you use it over the internet.
