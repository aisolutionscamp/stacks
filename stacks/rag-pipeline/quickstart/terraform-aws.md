## Quick start (Terraform, AWS)

This creates billable resources (an `m7i.xlarge` instance by default, a 60 GB gp3 volume and two SSM parameters). Run `terraform plan` first.

1. Requirements: Terraform 1.5 or newer, AWS credentials, and the AWS CLI with the Session Manager plugin for shell access.
2. Get the configuration:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/rag-pipeline/terraform/aws
   ```
3. Set the keys and your IP range (only this range can reach rag-api):
   ```bash
   export TF_VAR_qdrant_api_key=$(openssl rand -hex 32)
   export TF_VAR_rag_api_key=$(openssl rand -hex 32)
   export TF_VAR_allowed_cidr="$(curl -s https://checkip.amazonaws.com)/32"
   ```
4. Deploy (for a GPU add `-var gpu_instance_type=g5.xlarge`):
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
5. The instance installs Docker and starts the stack on boot; the first start downloads about 6 GB of images and models. Follow it through SSM:
   ```bash
   $(terraform output -raw ssm_session_command)
   sudo tail -f /var/log/rag-pipeline-setup.log
   sudo docker compose -f /opt/stacks/stacks/rag-pipeline/compose.yaml logs -f rag-api
   ```
6. Ask a question:
   ```bash
   curl -s "$(terraform output -raw rag_api_url)/health"
   curl -s -X POST "$(terraform output -raw rag_api_url)/query" -H "X-API-Key: $TF_VAR_rag_api_key" \
     -H 'Content-Type: application/json' -d '{"question":"Hello?"}'
   ```
   The API uses plain HTTP. For production put a load balancer or proxy with TLS in front, or skip the public port and reach rag-api through SSM port forwarding (like the `qdrant_dashboard_tunnel` output, with `portNumber=8000`).
7. Remove everything with `terraform destroy`.
