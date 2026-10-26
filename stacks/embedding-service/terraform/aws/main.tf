# Embedding Service on AWS: one EC2 instance that runs Hugging Face Text
# Embeddings Inference (TEI) with Docker Compose, set up by user_data.
#
# - CPU instance by default (Amazon Linux 2023), optional NVIDIA GPU instance
#   (Deep Learning Base OSS Nvidia Driver GPU AMI, Amazon Linux 2023).
# - The API key is stored in SSM Parameter Store (SecureString) and read by the
#   instance at boot. Every request except /health and /metrics needs it.
# - The API port is open only to allowed_cidr. There is no SSH; use SSM Session
#   Manager for shell access.
# - Traffic is plain HTTP. Put a TLS-terminating load balancer or reverse proxy
#   in front of it before sending data over the internet.
#
#   terraform init
#   terraform apply -var 'allowed_cidr=203.0.113.10/32' -var "api_key=$(openssl rand -hex 32)"

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "embedding-service"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the API, e.g. your office IP as 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.allowed_cidr)) && var.allowed_cidr != "0.0.0.0/0"
    error_message = "allowed_cidr must be a valid IPv4 CIDR and not 0.0.0.0/0."
  }
}

variable "api_key" {
  description = "API key for the service (requests need 'Authorization: Bearer <key>'). Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.api_key) >= 32
    error_message = "api_key must be at least 32 characters."
  }
}

variable "hf_token" {
  description = "Optional Hugging Face token for gated or private models."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gpu" {
  description = "Use an NVIDIA GPU instance, the GPU AMI and the cuda TEI image."
  type        = bool
  default     = false
}

variable "instance_type" {
  description = "EC2 instance type. Empty picks c7i.xlarge (4 vCPU, 8 GiB) for CPU or g5.xlarge (1x A10G) for GPU."
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "Root volume size in GiB (OS, images and model cache). The cuda image alone is about 3 GB compressed."
  type        = number
  default     = 40
}

variable "embed_model_id" {
  description = "Hugging Face model for embeddings."
  type        = string
  default     = "BAAI/bge-base-en-v1.5"
}

variable "embed_model_revision" {
  description = "Model revision (branch, tag or commit hash)."
  type        = string
  default     = "main"
}

variable "enable_reranker" {
  description = "Also run a reranker service on port 8081."
  type        = bool
  default     = false
}

variable "rerank_model_id" {
  description = "Hugging Face model for the reranker."
  type        = string
  default     = "BAAI/bge-reranker-base"
}

variable "subnet_id" {
  description = "Subnet for the instance (needs internet access for image and model downloads). Empty uses a subnet of the default VPC."
  type        = string
  default     = ""
}

locals {
  instance_type = var.instance_type != "" ? var.instance_type : (var.gpu ? "g5.xlarge" : "c7i.xlarge")
  image         = var.gpu ? "ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.4" : "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4"
  ami_parameter = var.gpu ? "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id" : "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  subnet_id     = var.subnet_id != "" ? var.subnet_id : data.aws_subnets.default.ids[0]
  vpc_id        = data.aws_subnet.selected.vpc_id

  # Same services as compose.yaml, written as compose.yaml on the instance.
  # The cuda image keeps its own entrypoint script (it picks the build for the
  # GPU); the CPU image runs with a read-only root filesystem.
  # "$$" is how Compose writes a literal "$".
  load_secrets = "export API_KEY=\"$$(cat /run/secrets/api_key)\"; [ -s /run/secrets/hf_token ] && export HF_TOKEN=\"$$(cat /run/secrets/hf_token)\";"
  base_service = {
    image        = local.image
    restart      = "unless-stopped"
    entrypoint   = ["/bin/sh", "-c", "${local.load_secrets} exec ${var.gpu ? "/entrypoint.sh" : "text-embeddings-router"} --json-output"]
    read_only    = !var.gpu
    tmpfs        = ["/tmp"]
    cap_drop     = ["ALL"]
    security_opt = ["no-new-privileges:true"]
    secrets      = ["api_key", "hf_token"]
    volumes      = ["models:/data"]
    healthcheck = {
      test         = ["CMD", "curl", "-fsS", "http://localhost:80/health"]
      interval     = "15s"
      timeout      = "5s"
      retries      = 3
      start_period = "15m"
    }
  }
  # Indexing an object picks one variant (a conditional would need equal types).
  gpu_settings = {
    cpu = {}
    gpu = {
      shm_size = "1gb"
      deploy = {
        resources = {
          reservations = {
            devices = [{ driver = "nvidia", count = 1, capabilities = ["gpu"] }]
          }
        }
      }
    }
  }[var.gpu ? "gpu" : "cpu"]
  tei_env = {
    HOSTNAME              = "0.0.0.0"
    PORT                  = "80"
    MAX_CLIENT_BATCH_SIZE = "32"
    AUTO_TRUNCATE         = "true"
  }

  compose = yamlencode({
    services = merge(
      {
        embeddings = merge(local.base_service, local.gpu_settings, {
          environment = merge(local.tei_env, { MODEL_ID = var.embed_model_id, REVISION = var.embed_model_revision })
          ports       = ["8080:80"]
        })
      },
      var.enable_reranker ? {
        reranker = merge(local.base_service, local.gpu_settings, {
          environment = merge(local.tei_env, { MODEL_ID = var.rerank_model_id })
          ports       = ["8081:80"]
        })
      } : {},
    )
    secrets = {
      api_key  = { file = "./secrets/api_key" }
      hf_token = { file = "./secrets/hf_token" }
    }
    volumes = { models = {} }
  })

  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    command -v docker >/dev/null || dnf install -y docker
    systemctl enable --now docker

    if ! docker compose version >/dev/null 2>&1; then
      mkdir -p /usr/local/lib/docker/cli-plugins
      curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
        https://github.com/docker/compose/releases/download/v5.6.1/docker-compose-linux-x86_64
      echo "47737f4236e6d3ccea7291995203f8f018058783b4c3a9469119811a0b5db8c0  /usr/local/lib/docker/cli-plugins/docker-compose" | sha256sum -c -
      chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
    fi

    %{if var.gpu~}
    if ! command -v nvidia-ctk >/dev/null; then
      curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
      dnf install -y nvidia-container-toolkit
    fi
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    %{endif~}

    mkdir -p /opt/embedding-service/secrets
    cd /opt/embedding-service
    umask 077
    aws ssm get-parameter --region ${var.region} --with-decryption \
      --name ${aws_ssm_parameter.api_key.name} --query Parameter.Value --output text > secrets/api_key
    %{if var.hf_token != ""~}
    aws ssm get-parameter --region ${var.region} --with-decryption \
      --name ${aws_ssm_parameter.hf_token[0].name} --query Parameter.Value --output text > secrets/hf_token
    %{else~}
    : > secrets/hf_token
    %{endif~}
    # Compose secrets are bind mounts; the container user (root) reads them.
    chmod 600 secrets/*

    cat > compose.yaml <<'COMPOSE'
    ${local.compose}
    COMPOSE

    docker compose up -d --wait --wait-timeout 1800
  EOT
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

data "aws_ssm_parameter" "ami" {
  name = local.ami_parameter
}

resource "aws_ssm_parameter" "api_key" {
  name  = "/${var.name}/api-key"
  type  = "SecureString"
  value = var.api_key
}

resource "aws_ssm_parameter" "hf_token" {
  count = var.hf_token != "" ? 1 : 0
  name  = "/${var.name}/hf-token"
  type  = "SecureString"
  value = var.hf_token
}

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

# Session Manager access instead of SSH.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "read_secrets" {
  name = "read-secrets"
  role = aws_iam_role.instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = concat([aws_ssm_parameter.api_key.arn], aws_ssm_parameter.hf_token[*].arn)
    }]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name        = var.name
  description = "Embedding Service API, limited to allowed_cidr"
  vpc_id      = local.vpc_id

  ingress {
    description = "Embeddings API"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  dynamic "ingress" {
    for_each = var.enable_reranker ? [1] : []
    content {
      description = "Reranker API"
      from_port   = 8081
      to_port     = 8081
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    description = "Image and model downloads, SSM"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = local.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.instance.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = true
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = var.name
  }
}

output "embeddings_url" {
  description = "Embeddings API (POST /embed, POST /v1/embeddings). The first start downloads the image and model."
  value       = "http://${aws_instance.this.public_ip}:8080"
}

output "reranker_url" {
  description = "Reranker API (POST /rerank), if enabled."
  value       = var.enable_reranker ? "http://${aws_instance.this.public_ip}:8081" : null
}

output "instance_id" {
  description = "Connect with: aws ssm start-session --target <instance_id>"
  value       = aws_instance.this.id
}

output "api_key_parameter" {
  description = "SSM parameter that holds the API key."
  value       = aws_ssm_parameter.api_key.name
}
