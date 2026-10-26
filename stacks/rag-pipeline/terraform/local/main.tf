# RAG Pipeline on one Docker host: Qdrant + Ollama + rag-api.
# Same containers as compose.yaml. Usage:
#   export TF_VAR_qdrant_api_key=$(openssl rand -hex 32)
#   export TF_VAR_rag_api_key=$(openssl rand -hex 32)
#   terraform init && terraform apply

terraform {
  required_version = ">= 1.5"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 4.6"
    }
  }
}

provider "docker" {
  # Local Docker by default. For a remote host: host = "ssh://user@host"
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

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

variable "name_prefix" {
  description = "Prefix for container, network and volume names."
  type        = string
  default     = "rag-pipeline"
}

variable "rag_api_image" {
  description = "rag-api image. Published from stacks/rag-pipeline/app."
  type        = string
  default     = "ghcr.io/aisolutionscamp/rag-api:1.0.0"
}

variable "build_rag_api" {
  description = "Build the rag-api image from ../../app instead of pulling it."
  type        = bool
  default     = false
}

variable "embed_model" {
  description = "Ollama embedding model."
  type        = string
  default     = "nomic-embed-text:v1.5"
}

variable "chat_model" {
  description = "Ollama chat model that writes the answers."
  type        = string
  default     = "llama3.2:3b"
}

variable "collection" {
  description = "Qdrant collection name."
  type        = string
  default     = "documents"
}

variable "bind_address" {
  description = "Host address the ports are published on. Keep 127.0.0.1 unless a firewall or TLS proxy is in front."
  type        = string
  default     = "127.0.0.1"
}

variable "rag_api_port" {
  description = "Host port for rag-api."
  type        = number
  default     = 8000
}

variable "qdrant_port" {
  description = "Host port for the Qdrant REST API and dashboard (always on 127.0.0.1)."
  type        = number
  default     = 6333
}

variable "ollama_port" {
  description = "Host port for Ollama (always on 127.0.0.1, Ollama has no authentication)."
  type        = number
  default     = 11434
}

variable "gpu" {
  description = "Give Ollama all GPUs (needs the NVIDIA Container Toolkit on the host)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Network, volumes, images
# ---------------------------------------------------------------------------

resource "docker_network" "rag" {
  name = var.name_prefix
}

resource "docker_volume" "qdrant" {
  name = "${var.name_prefix}-qdrant"
}

resource "docker_volume" "ollama" {
  name = "${var.name_prefix}-ollama"
}

resource "docker_image" "qdrant" {
  name         = "qdrant/qdrant:v1.20.0"
  keep_locally = true
}

resource "docker_image" "ollama" {
  name         = "ollama/ollama:0.40.11"
  keep_locally = true
}

resource "docker_image" "rag_api" {
  name         = var.rag_api_image
  keep_locally = true

  dynamic "build" {
    for_each = var.build_rag_api ? [1] : []
    content {
      context = "${path.module}/../../app"
    }
  }
}

# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------

resource "docker_container" "qdrant" {
  name     = "${var.name_prefix}-qdrant"
  image    = docker_image.qdrant.image_id
  restart  = "unless-stopped"
  must_run = true

  env = [
    "QDRANT__SERVICE__API_KEY=${var.qdrant_api_key}",
    "QDRANT__TELEMETRY_DISABLED=true",
  ]

  networks_advanced {
    name    = docker_network.rag.id
    aliases = ["qdrant"]
  }

  ports {
    internal = 6333
    external = var.qdrant_port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.qdrant.name
    container_path = "/qdrant/storage"
  }

  healthcheck {
    test         = ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/6333 && printf 'GET /readyz HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q ' 200 ' <&3"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "10s"
  }

  wait         = true
  wait_timeout = 120
}

resource "docker_container" "ollama" {
  name     = "${var.name_prefix}-ollama"
  image    = docker_image.ollama.image_id
  restart  = "unless-stopped"
  must_run = true
  gpus     = var.gpu ? "all" : null

  env = ["OLLAMA_KEEP_ALIVE=5m"]

  networks_advanced {
    name    = docker_network.rag.id
    aliases = ["ollama"]
  }

  ports {
    internal = 11434
    external = var.ollama_port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.ollama.name
    container_path = "/root/.ollama"
  }

  healthcheck {
    test         = ["CMD", "ollama", "list"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 6
    start_period = "10s"
  }

  wait         = true
  wait_timeout = 120
}

resource "docker_container" "rag_api" {
  name     = "${var.name_prefix}-rag-api"
  image    = docker_image.rag_api.image_id
  restart  = "unless-stopped"
  must_run = true

  env = [
    "OLLAMA_URL=http://ollama:11434",
    "QDRANT_URL=http://qdrant:6333",
    "QDRANT_API_KEY=${var.qdrant_api_key}",
    "QDRANT_COLLECTION=${var.collection}",
    "RAG_API_KEY=${var.rag_api_key}",
    "EMBED_MODEL=${var.embed_model}",
    "CHAT_MODEL=${var.chat_model}",
    "PULL_MODELS=true",
  ]

  networks_advanced {
    name = docker_network.rag.id
  }

  ports {
    internal = 8000
    external = var.rag_api_port
    ip       = var.bind_address
  }

  read_only = true
  tmpfs     = { "/tmp" = "" }
  capabilities { drop = ["ALL"] }
  security_opts = ["no-new-privileges:true"]

  # Healthy once both models are pulled and the Qdrant collection exists.
  healthcheck {
    test           = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=4)"]
    interval       = "10s"
    timeout        = "5s"
    retries        = 3
    start_period   = "30m"
    start_interval = "5s"
  }

  # The first start downloads the models (about 2.3 GB with the defaults).
  wait         = true
  wait_timeout = 1800

  depends_on = [docker_container.qdrant, docker_container.ollama]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "rag_api_url" {
  description = "rag-api base URL (POST /ingest, POST /query, GET /health)."
  value       = "http://${var.bind_address == "0.0.0.0" ? "127.0.0.1" : var.bind_address}:${var.rag_api_port}"
}

output "qdrant_dashboard_url" {
  description = "Qdrant dashboard (needs the Qdrant API key)."
  value       = "http://127.0.0.1:${var.qdrant_port}/dashboard"
}

output "ollama_url" {
  description = "Ollama API, local only."
  value       = "http://127.0.0.1:${var.ollama_port}"
}
