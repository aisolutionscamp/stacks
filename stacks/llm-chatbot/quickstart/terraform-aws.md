1. Requirements: an AWS account, AWS CLI with credentials, Terraform 1.5 or newer, and the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for shell access. This creates billable resources (EC2 instance, EBS volume).
2. Get the files:
   ```bash
   git clone https://github.com/aisolutionscamp/stacks.git
   cd stacks/stacks/llm-chatbot/terraform/aws
   ```
3. Set the variables:
   ```bash
   export TF_VAR_webui_secret_key="$(openssl rand -hex 32)"
   export TF_VAR_allowed_cidr="$(curl -fsS https://checkip.amazonaws.com)/32"
   ```
   GPU: `export TF_VAR_gpu=true TF_VAR_instance_type=g4dn.xlarge` (check your GPU instance quota first).
4. Review and deploy:
   ```bash
   terraform init
   terraform plan
   terraform apply
   ```
5. Wait several minutes for the first boot (Docker install, image and model download), then open `terraform output -raw open_webui_url` and create the first account (it becomes the admin).
6. Turn off new sign-ups in Admin Panel > Settings > General.
7. Shell on the instance: `terraform output -raw ssm_shell`. Boot log: `sudo tail -f /var/log/cloud-init-output.log`.
8. Remove: `terraform destroy`.

The connection uses plain HTTP. For real use, add TLS (load balancer or reverse proxy) or use the SSM port forward from `terraform output -raw ssm_port_forward`.
