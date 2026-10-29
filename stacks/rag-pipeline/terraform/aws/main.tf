# RAG Pipeline on AWS: one EC2 instance that runs the compose stack
# (Qdrant + Ollama + rag-api) from github.com/aisolutionscamp/stacks.
#
# - Ubuntu 24.04, Docker Engine and the Compose plugin from Docker's apt repository
# - CPU instance by default; set gpu_instance_type to run Ollama on an NVIDIA GPU
#   (uses the AWS Deep Learning Base GPU AMI, which ships the driver and toolkit)
# - No SSH: shell access through AWS Systems Manager Session Manager
# - Only rag-api is reachable, and only from allowed_cidr; Qdrant and Ollama
#   stay on the instance's localhost
# - API keys are stored as SSM SecureString parameters and read at boot
#
# Usage:
#   export TF_VAR_qdrant_api_key=$(openssl rand -hex 32)
#   export TF_VAR_rag_api_key=$(openssl rand -hex 32)
#   terraform init
#   terraform apply -var allowed_cidr=203.0.113.10/32

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
  region = var.region
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "rag-pipeline"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach rag-api, e.g. your office IP as 203.0.113.10/32."
  type        = string
  validation {
    condition     = can(cidrhost(var.allowed_cidr, 0)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a valid CIDR and not 0.0.0.0/0."
  }
}

variable "qdrant_api_key" {
  description = "API key for Qdrant. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.qdrant_api_key) >= 16
    error_message = "qdrant_api_key must be at least 16 characters."
  }
}

variable "rag_api_key" {
  description = "API key clients send to rag-api (X-API-Key header). Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.rag_api_key) >= 16
    error_message = "rag_api_key must be at least 16 characters."
  }
}

variable "instance_type" {
  description = "CPU instance type. 4 vCPU and 16 GB RAM run the default 3B chat model at a usable speed."
  type        = string
  default     = "m7i.xlarge"
}

variable "gpu_instance_type" {
  description = "Optional NVIDIA GPU instance type (e.g. g5.xlarge). When set, it replaces instance_type and Ollama uses the GPU."
  type        = string
  default     = ""
}

variable "root_volume_gb" {
  description = "Root volume size in GB (images about 4 GB, default models about 2.3 GB, plus your vectors)."
  type        = number
  default     = 60
}

variable "subnet_id" {
  description = "Subnet with internet access (public IP or NAT). Empty uses a default-VPC subnet."
  type        = string
  default     = ""
}

variable "rag_api_port" {
  description = "Port rag-api listens on."
  type        = number
  default     = 8000
}

variable "embed_model" {
  description = "Ollama embedding model."
  type        = string
  default     = "nomic-embed-text:v1.5"
}

variable "chat_model" {
  description = "Ollama chat model."
  type        = string
  default     = "llama3.2:3b"
}

variable "stacks_ref" {
  description = "Git branch or tag of github.com/aisolutionscamp/stacks to deploy."
  type        = string
  default     = "main"
}

variable "rag_api_version" {
  description = "Tag of ghcr.io/aisolutionscamp/rag-api."
  type        = string
  default     = "1.0.1"
}

locals {
  gpu           = var.gpu_instance_type != ""
  instance_type = local.gpu ? var.gpu_instance_type : var.instance_type
  subnet_id     = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default[0].ids[0]
  compose_files = local.gpu ? "-f compose.yaml -f compose.gpu.yaml" : "-f compose.yaml"
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

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
  id = local.subnet_id
}

resource "aws_security_group" "rag" {
  name        = "${var.name}-sg"
  description = "rag-api from allowed_cidr only; no SSH (use SSM Session Manager)"
  vpc_id      = data.aws_subnet.selected.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "rag_api" {
  security_group_id = aws_security_group.rag.id
  description       = "rag-api"
  cidr_ipv4         = var.allowed_cidr
  ip_protocol       = "tcp"
  from_port         = var.rag_api_port
  to_port           = var.rag_api_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.rag.id
  description       = "Outbound for packages, images, models and SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------------------------------------------------------------------------
# Secrets (SSM Parameter Store, encrypted with the AWS managed key)
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "qdrant_api_key" {
  name  = "/${var.name}/qdrant-api-key"
  type  = "SecureString"
  value = var.qdrant_api_key
}

resource "aws_ssm_parameter" "rag_api_key" {
  name  = "/${var.name}/rag-api-key"
  type  = "SecureString"
  value = var.rag_api_key
}

# ---------------------------------------------------------------------------
# IAM: SSM Session Manager + read the two parameters
# ---------------------------------------------------------------------------

resource "aws_iam_role" "rag" {
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
  role       = aws_iam_role.rag.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "read-rag-secrets"
  role = aws_iam_role.rag.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = [aws_ssm_parameter.qdrant_api_key.arn, aws_ssm_parameter.rag_api_key.arn]
    }]
  })
}

resource "aws_iam_instance_profile" "rag" {
  name = "${var.name}-instance"
  role = aws_iam_role.rag.name
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "ami" {
  name = local.gpu ? "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id" : "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "rag" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ami.value)
  instance_type               = local.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.rag.id]
  iam_instance_profile        = aws_iam_instance_profile.rag.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    exec > >(tee -a /var/log/rag-pipeline-setup.log) 2>&1

    # Docker Engine and Compose plugin from Docker's apt repository
    if ! docker compose version >/dev/null 2>&1; then
      apt-get update
      apt-get install -y ca-certificates curl git
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    command -v git >/dev/null || apt-get install -y git
    systemctl enable --now docker

    # Stack files
    rm -rf /opt/stacks
    git clone --depth 1 --branch '${var.stacks_ref}' https://github.com/aisolutionscamp/stacks.git /opt/stacks
    cd /opt/stacks/stacks/rag-pipeline

    # Secrets from SSM Parameter Store (via the instance role)
    ssm_get() {
      docker run --rm --network host amazon/aws-cli:2.38.5 ssm get-parameter \
        --region '${var.region}' --with-decryption --name "$1" --query Parameter.Value --output text
    }
    umask 077
    cp .env.example .env
    {
      echo "QDRANT_API_KEY=$(ssm_get '${aws_ssm_parameter.qdrant_api_key.name}')"
      echo "RAG_API_KEY=$(ssm_get '${aws_ssm_parameter.rag_api_key.name}')"
      echo "RAG_API_BIND=0.0.0.0"
      echo "RAG_API_PORT=${var.rag_api_port}"
      echo "EMBED_MODEL=${var.embed_model}"
      echo "CHAT_MODEL=${var.chat_model}"
      echo "RAG_API_VERSION=${var.rag_api_version}"
    } >> .env

    # Start; containers restart with Docker after a reboot. The first start
    # pulls the models; check progress with: docker compose logs -f rag-api
    docker compose ${local.compose_files} pull
    docker compose ${local.compose_files} up -d --no-build
  EOT

  tags = {
    Name = var.name
  }

  depends_on = [aws_iam_role_policy.read_secrets, aws_iam_role_policy_attachment.ssm_core]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.rag.id
}

output "rag_api_url" {
  description = "rag-api base URL (plain HTTP; put a TLS proxy or load balancer in front for production)."
  value       = "http://${aws_instance.rag.public_ip}:${var.rag_api_port}"
}

output "ssm_session_command" {
  description = "Shell on the instance without SSH."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.rag.id}"
}

output "qdrant_dashboard_tunnel" {
  description = "Forward the Qdrant dashboard to http://localhost:6333/dashboard through SSM."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.rag.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=6333,localPortNumber=6333"
}
