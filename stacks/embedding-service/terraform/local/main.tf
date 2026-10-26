# Embedding Service on one machine with the Docker provider.
# Same containers as compose.yaml: Hugging Face Text Embeddings Inference (TEI)
# for embeddings, plus an optional reranker.
#
#   terraform init
#   terraform apply -var 'api_key=...'      # api_key is optional

terraform {
  required_version = ">= 1.6"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.0"
    }
  }
}

provider "docker" {}

variable "name_prefix" {
  description = "Prefix for container, volume and network names."
  type        = string
  default     = "embedding-service"
}

variable "image" {
  description = "TEI image. Use ghcr.io/huggingface/text-embeddings-inference:cuda-1.9.4 with gpu = true."
  type        = string
  default     = "ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.4"
}

variable "gpu" {
  description = "Pass all NVIDIA GPUs to the containers (needs the NVIDIA Container Toolkit and the cuda image)."
  type        = bool
  default     = false
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

variable "embed_port" {
  description = "Host port for the embeddings API (bound to 127.0.0.1)."
  type        = number
  default     = 8080
}

variable "enable_reranker" {
  description = "Also run a reranker service."
  type        = bool
  default     = false
}

variable "rerank_model_id" {
  description = "Hugging Face model for the reranker."
  type        = string
  default     = "BAAI/bge-reranker-base"
}

variable "rerank_model_revision" {
  description = "Reranker model revision."
  type        = string
  default     = "main"
}

variable "rerank_port" {
  description = "Host port for the reranker API (bound to 127.0.0.1)."
  type        = number
  default     = 8081
}

variable "api_key" {
  description = "Optional API key (requests need 'Authorization: Bearer <key>'). Empty disables it. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  default     = ""
}

variable "hf_token" {
  description = "Optional Hugging Face token for gated or private models."
  type        = string
  sensitive   = true
  default     = ""
}

variable "max_client_batch_size" {
  description = "Maximum number of inputs per request."
  type        = number
  default     = 32
}

locals {
  # TEI treats an empty API_KEY as a key that never matches, so optional
  # values are only set when they are not empty.
  common_env = concat(
    [
      "HOSTNAME=0.0.0.0",
      "PORT=80",
      "MAX_CLIENT_BATCH_SIZE=${var.max_client_batch_size}",
      "AUTO_TRUNCATE=true",
    ],
    var.api_key != "" ? ["API_KEY=${var.api_key}"] : [],
    var.hf_token != "" ? ["HF_TOKEN=${var.hf_token}"] : [],
  )

  services = merge(
    {
      embeddings = {
        model    = var.embed_model_id
        revision = var.embed_model_revision
        port     = var.embed_port
      }
    },
    var.enable_reranker ? {
      reranker = {
        model    = var.rerank_model_id
        revision = var.rerank_model_revision
        port     = var.rerank_port
      }
    } : {},
  )
}

resource "docker_image" "tei" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "models" {
  name = "${var.name_prefix}-models"
}

resource "docker_network" "embedding" {
  name = var.name_prefix
}

resource "docker_container" "tei" {
  for_each = local.services

  name     = "${var.name_prefix}-${each.key}"
  image    = docker_image.tei.image_id
  restart  = "unless-stopped"
  command  = ["--json-output"]
  gpus     = var.gpu ? "all" : null
  shm_size = var.gpu ? 1024 : null

  env = concat(local.common_env, [
    "MODEL_ID=${each.value.model}",
    "REVISION=${each.value.revision}",
  ])

  # The cuda image's entrypoint may run ldconfig, so only the CPU image
  # gets a read-only root filesystem.
  read_only = !var.gpu
  tmpfs = {
    "/tmp" = "rw"
  }
  capabilities {
    drop = ["ALL"]
  }
  security_opts = ["no-new-privileges:true"]

  networks_advanced {
    name    = docker_network.embedding.id
    aliases = [each.key]
  }

  ports {
    internal = 80
    external = each.value.port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.models.name
    container_path = "/data"
  }

  healthcheck {
    test         = ["CMD", "curl", "-fsS", "http://localhost:80/health"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 3
    start_period = "15m"
  }
}

output "embeddings_url" {
  description = "Embeddings API (POST /embed, POST /v1/embeddings)."
  value       = "http://127.0.0.1:${var.embed_port}"
}

output "reranker_url" {
  description = "Reranker API (POST /rerank), if enabled."
  value       = var.enable_reranker ? "http://127.0.0.1:${var.rerank_port}" : null
}

output "test_command" {
  description = "Request one embedding (drop the Authorization header if no api_key is set)."
  value       = "curl http://127.0.0.1:${var.embed_port}/embed -H 'Content-Type: application/json' -H \"Authorization: Bearer $API_KEY\" -d '{\"inputs\":\"Hello world\"}'"
}
