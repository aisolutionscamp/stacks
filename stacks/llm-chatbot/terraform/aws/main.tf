# LLM Chatbot (Ollama + Open WebUI) on one EC2 instance in AWS.
# The instance installs Docker and runs the same compose stack as compose.yaml (via user_data).
# Access: Open WebUI on port 80, only from allowed_cidr. No SSH; use SSM Session Manager.
# The secret key is stored as an SSM SecureString parameter and read by the instance at boot.
# No TLS: put a load balancer or reverse proxy with a certificate in front before real use,
# or keep allowed_cidr narrow / use the SSM port forward from the outputs.
#
#   export TF_VAR_webui_secret_key="$(openssl rand -hex 32)"
#   export TF_VAR_allowed_cidr="203.0.113.10/32"   # your IP
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "llm-chatbot"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach Open WebUI on port 80, e.g. your IP as 203.0.113.10/32."
  type        = string
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a valid CIDR and not 0.0.0.0/0."
  }
}

variable "webui_secret_key" {
  description = "Signs Open WebUI sessions. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.webui_secret_key) >= 32
    error_message = "webui_secret_key must be at least 32 characters (openssl rand -hex 32)."
  }
}

variable "gpu" {
  description = "Use an NVIDIA GPU instance: switches to the AWS Deep Learning Base GPU AMI and enables the GPU in Docker. Set instance_type to a GPU type such as g4dn.xlarge."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type. CPU: t3.xlarge (4 vCPU, 16 GiB) runs 1B-3B models. GPU (gpu = true): e.g. g4dn.xlarge (NVIDIA T4, 16 GB)."
  type        = string
  default     = "t3.xlarge"
}

variable "volume_size_gb" {
  description = "Root volume size in GB (OS, Docker images of about 15 GB, and models)."
  type        = number
  default     = 60
}

variable "subnet_id" {
  description = "Subnet for the instance (needs outbound internet access). Empty: a default subnet of the default VPC."
  type        = string
  default     = ""
}

variable "default_model" {
  description = "Ollama model pulled at boot and preselected in Open WebUI (empty: skip)."
  type        = string
  default     = "llama3.2"
}

variable "ollama_version" {
  description = "ollama/ollama image tag."
  type        = string
  default     = "0.40.11"
}

variable "open_webui_version" {
  description = "ghcr.io/open-webui/open-webui image tag."
  type        = string
  default     = "0.12.4"
}

# --- Network ----------------------------------------------------------------

data "aws_vpc" "default" {
  count   = var.subnet_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "selected" {
  id = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]
}

resource "aws_security_group" "chatbot" {
  name        = "${var.name}-sg"
  description = "Open WebUI from allowed_cidr only; no SSH"
  vpc_id      = data.aws_subnet.selected.vpc_id

  ingress {
    description = "Open WebUI"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "Image, package and model downloads, SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-sg" }
}

# --- Secret -----------------------------------------------------------------

resource "aws_ssm_parameter" "webui_secret_key" {
  name        = "/${var.name}/webui-secret-key"
  description = "Open WebUI WEBUI_SECRET_KEY"
  type        = "SecureString"
  value       = var.webui_secret_key
}

# --- IAM: SSM Session Manager + read the secret ------------------------------

resource "aws_iam_role" "instance" {
  name = "${var.name}-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secret" {
  name = "read-webui-secret"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.webui_secret_key.arn
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

# --- Instance ---------------------------------------------------------------

data "aws_ssm_parameter" "ami" {
  name = var.gpu ? "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id" : "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  gpu_block = var.gpu ? join("\n", [
    "    deploy:",
    "      resources:",
    "        reservations:",
    "          devices:",
    "            - driver: nvidia",
    "              count: all",
    "              capabilities: [gpu]",
  ]) : ""

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Docker Engine + compose plugin from Docker's apt repository (skipped if already installed).
    if ! command -v docker >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi

    if [ "${var.gpu}" = "true" ] && ! command -v nvidia-ctk >/dev/null 2>&1; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
      curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list
      apt-get update
      apt-get install -y nvidia-container-toolkit
    fi
    if [ "${var.gpu}" = "true" ]; then
      nvidia-ctk runtime configure --runtime=docker
      systemctl restart docker
    fi

    command -v aws >/dev/null 2>&1 || snap install aws-cli --classic
    export PATH="$PATH:/snap/bin"

    mkdir -p /opt/llm-chatbot
    cd /opt/llm-chatbot
    umask 077
    {
      echo "WEBUI_SECRET_KEY=$(aws ssm get-parameter --region ${var.aws_region} --name ${aws_ssm_parameter.webui_secret_key.name} --with-decryption --query Parameter.Value --output text)"
      echo "DEFAULT_MODEL=${var.default_model}"
    } > .env

    cat > compose.yaml <<'COMPOSE'
    name: llm-chatbot
    services:
      ollama:
        image: ollama/ollama:${var.ollama_version}
        restart: unless-stopped
        environment:
          OLLAMA_KEEP_ALIVE: 5m
          OLLAMA_NUM_PARALLEL: "1"
          OLLAMA_MAX_LOADED_MODELS: "1"
        volumes:
          - ollama-data:/root/.ollama
        healthcheck:
          test: ["CMD", "ollama", "list"]
          interval: 10s
          timeout: 5s
          retries: 12
    ${local.gpu_block}
      model-pull:
        image: ollama/ollama:${var.ollama_version}
        restart: "no"
        depends_on:
          ollama:
            condition: service_healthy
        environment:
          OLLAMA_HOST: http://ollama:11434
          DEFAULT_MODEL: $${DEFAULT_MODEL}
        entrypoint: ["/bin/sh", "-c"]
        command:
          - '[ -z "$$DEFAULT_MODEL" ] || ollama pull "$$DEFAULT_MODEL"'
      open-webui:
        image: ghcr.io/open-webui/open-webui:${var.open_webui_version}
        restart: unless-stopped
        depends_on:
          ollama:
            condition: service_healthy
        environment:
          OLLAMA_BASE_URL: http://ollama:11434
          WEBUI_SECRET_KEY: $${WEBUI_SECRET_KEY:?set WEBUI_SECRET_KEY}
          WEBUI_NAME: LLM Chatbot
          ENABLE_SIGNUP: "true"
          DEFAULT_USER_ROLE: pending
          DEFAULT_MODELS: $${DEFAULT_MODEL}
          ENABLE_OPENAI_API: "false"
        volumes:
          - open-webui-data:/app/backend/data
        ports:
          - "80:8080"
        healthcheck:
          test: ["CMD-SHELL", "curl -fsS http://localhost:8080/health || exit 1"]
          interval: 15s
          timeout: 5s
          retries: 20
          start_period: 120s
    volumes:
      ollama-data:
      open-webui-data:
    COMPOSE

    docker compose up -d
  EOT
}

resource "aws_instance" "chatbot" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.selected.id
  vpc_security_group_ids      = [aws_security_group.chatbot.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.volume_size_gb
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = var.name }

  depends_on = [aws_iam_role_policy.read_secret, aws_iam_role_policy_attachment.ssm_core]

  lifecycle {
    # A newer AMI must not replace the instance (and its data) on the next apply.
    ignore_changes = [ami]
  }
}

output "open_webui_url" {
  description = "Chat UI (reachable from allowed_cidr). First boot takes several minutes. The first account becomes the admin."
  value       = "http://${aws_instance.chatbot.public_ip}"
}

output "instance_id" {
  value = aws_instance.chatbot.id
}

output "ssm_shell" {
  description = "Shell on the instance without SSH."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.chatbot.id}"
}

output "ssm_port_forward" {
  description = "Open WebUI on http://localhost:3000 through SSM, without opening port 80."
  value       = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.chatbot.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=80,localPortNumber=3000"
}
