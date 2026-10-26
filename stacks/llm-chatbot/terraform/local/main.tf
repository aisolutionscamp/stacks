# LLM Chatbot (Ollama + Open WebUI) on one machine with the Docker provider.
# Same containers as compose.yaml.
#
#   export TF_VAR_webui_secret_key="$(openssl rand -hex 32)"
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

provider "docker" {}

variable "webui_secret_key" {
  description = "Signs Open WebUI sessions. Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.webui_secret_key) >= 32
    error_message = "webui_secret_key must be at least 32 characters (openssl rand -hex 32)."
  }
}

variable "default_model" {
  description = "Ollama model pulled on apply and preselected in Open WebUI (empty: skip)."
  type        = string
  default     = "llama3.2"
}

variable "enable_signup" {
  description = "Allow new accounts. The first account becomes the admin. Only read on the first start."
  type        = bool
  default     = true
}

variable "webui_port" {
  description = "Host port for Open WebUI (bound to 127.0.0.1)."
  type        = number
  default     = 3000
}

variable "ollama_port" {
  description = "Host port for the Ollama API (bound to 127.0.0.1; no authentication)."
  type        = number
  default     = 11434
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

resource "docker_network" "chatbot" {
  name = "llm-chatbot"
}

resource "docker_volume" "ollama_data" {
  name = "llm-chatbot-ollama-data"
}

resource "docker_volume" "open_webui_data" {
  name = "llm-chatbot-open-webui-data"
}

resource "docker_image" "ollama" {
  name         = "ollama/ollama:${var.ollama_version}"
  keep_locally = true
}

resource "docker_image" "open_webui" {
  name         = "ghcr.io/open-webui/open-webui:${var.open_webui_version}"
  keep_locally = true
}

resource "docker_container" "ollama" {
  name    = "llm-chatbot-ollama"
  image   = docker_image.ollama.image_id
  restart = "unless-stopped"

  env = [
    "OLLAMA_KEEP_ALIVE=5m",
    "OLLAMA_NUM_PARALLEL=1",
    "OLLAMA_MAX_LOADED_MODELS=1",
  ]

  networks_advanced {
    name    = docker_network.chatbot.name
    aliases = ["ollama"]
  }

  ports {
    internal = 11434
    external = var.ollama_port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.ollama_data.name
    container_path = "/root/.ollama"
  }

  healthcheck {
    test         = ["CMD", "ollama", "list"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 12
    start_period = "10s"
  }

  wait         = true
  wait_timeout = 120
}

# One-shot job: pulls the default model into the Ollama volume.
resource "docker_container" "model_pull" {
  count = var.default_model == "" ? 0 : 1

  name     = "llm-chatbot-model-pull"
  image    = docker_image.ollama.image_id
  restart  = "no"
  must_run = false
  attach   = true
  logs     = true

  entrypoint = ["/bin/ollama"]
  command    = ["pull", var.default_model]
  env        = ["OLLAMA_HOST=http://ollama:11434"]

  networks_advanced {
    name = docker_network.chatbot.name
  }

  depends_on = [docker_container.ollama]
}

resource "docker_container" "open_webui" {
  name    = "llm-chatbot-open-webui"
  image   = docker_image.open_webui.image_id
  restart = "unless-stopped"

  env = [
    "OLLAMA_BASE_URL=http://ollama:11434",
    "WEBUI_SECRET_KEY=${var.webui_secret_key}",
    "WEBUI_NAME=LLM Chatbot",
    "WEBUI_URL=http://localhost:${var.webui_port}",
    "ENABLE_SIGNUP=${var.enable_signup}",
    "DEFAULT_USER_ROLE=pending",
    "DEFAULT_MODELS=${var.default_model}",
    "ENABLE_OPENAI_API=false",
  ]

  networks_advanced {
    name = docker_network.chatbot.name
  }

  ports {
    internal = 8080
    external = var.webui_port
    ip       = "127.0.0.1"
  }

  volumes {
    volume_name    = docker_volume.open_webui_data.name
    container_path = "/app/backend/data"
  }

  healthcheck {
    test         = ["CMD-SHELL", "curl -fsS http://localhost:8080/health || exit 1"]
    interval     = "15s"
    timeout      = "5s"
    retries      = 20
    start_period = "120s"
  }

  wait         = true
  wait_timeout = 600

  depends_on = [docker_container.ollama]
}

output "open_webui_url" {
  description = "Chat UI. The first account you create becomes the admin."
  value       = "http://localhost:${var.webui_port}"
}

output "ollama_url" {
  description = "Ollama API (local only)."
  value       = "http://localhost:${var.ollama_port}"
}
