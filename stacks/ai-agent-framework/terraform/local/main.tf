# AI Agent Framework on one machine with the Docker provider:
# Flowise + Ollama + PostgreSQL, the same containers as compose.yaml.
#
#   export TF_VAR_postgres_password=$(openssl rand -hex 32)   # and the other secrets, see README
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

# ---------------------------------------------------------------- variables

variable "flowise_port" {
  description = "Host port for the Flowise UI and API (bound to 127.0.0.1)"
  type        = number
  default     = 3000
}

variable "ollama_port" {
  description = "Host port for the Ollama API (bound to 127.0.0.1)"
  type        = number
  default     = 11434
}

variable "app_url" {
  description = "Public URL of Flowise; an https:// URL turns on secure cookies"
  type        = string
  default     = "http://localhost:3000"
}

variable "ollama_model" {
  description = "Model pulled on start; use one with tool calling for agents"
  type        = string
  default     = "llama3.2:3b"
}

variable "flowise_admin_name" {
  description = "Display name of the Flowise owner account"
  type        = string
  default     = "Admin"
}

variable "flowise_admin_email" {
  description = "Email of the Flowise owner account (created on first start)"
  type        = string
}

variable "flowise_admin_password" {
  description = "Password of the owner account: 8-128 chars, upper and lower case, digit, special character"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "Password of the flowise PostgreSQL user (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "flowise_secretkey_overwrite" {
  description = "Encryption key for credentials stored in Flowise (openssl rand -hex 32); keep it stable"
  type        = string
  sensitive   = true
}

variable "jwt_auth_token_secret" {
  description = "Secret that signs login tokens (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "jwt_refresh_token_secret" {
  description = "Secret that signs refresh tokens (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "express_session_secret" {
  description = "Secret that signs session cookies (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

variable "token_hash_secret" {
  description = "Secret that hashes reset and invite tokens (openssl rand -hex 32)"
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------- shared

locals {
  flowise_image  = "flowiseai/flowise:3.1.4"
  ollama_image   = "ollama/ollama:0.40.11"
  postgres_image = "postgres:17.11-alpine"

  setup_script = <<-EOT
    const e = process.env;
    const body = { user: { name: e.FLOWISE_ADMIN_NAME, email: e.FLOWISE_ADMIN_EMAIL, credential: e.FLOWISE_ADMIN_PASSWORD } };
    fetch("http://flowise:3000/api/v1/account/register", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body)
    }).then(async (r) => {
      const text = await r.text();
      if (r.ok) return console.log("Created Flowise owner account " + e.FLOWISE_ADMIN_EMAIL);
      if (text.includes("only have one organization")) return console.log("Owner account already exists, nothing to do");
      console.error("Account setup failed (HTTP " + r.status + "): " + text);
      process.exit(1);
    }).catch((err) => { console.error(err); process.exit(1); });
  EOT
}

resource "docker_network" "agents" {
  name = "ai-agent-framework"
}

resource "docker_volume" "postgres_data" {
  name = "ai-agent-framework-postgres"
}

resource "docker_volume" "ollama_data" {
  name = "ai-agent-framework-ollama"
}

resource "docker_volume" "flowise_data" {
  name = "ai-agent-framework-flowise"
}

resource "docker_image" "flowise" {
  name         = local.flowise_image
  keep_locally = true
}

resource "docker_image" "ollama" {
  name         = local.ollama_image
  keep_locally = true
}

resource "docker_image" "postgres" {
  name         = local.postgres_image
  keep_locally = true
}

# ---------------------------------------------------------------- PostgreSQL

resource "docker_container" "postgres" {
  name    = "ai-agent-framework-postgres"
  image   = docker_image.postgres.image_id
  restart = "unless-stopped"

  env = [
    "POSTGRES_DB=flowise",
    "POSTGRES_USER=flowise",
    "POSTGRES_PASSWORD=${var.postgres_password}",
  ]

  networks_advanced {
    name    = docker_network.agents.name
    aliases = ["postgres"]
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U flowise -d flowise"]
    interval = "5s"
    timeout  = "5s"
    retries  = 20
  }

  wait         = true
  wait_timeout = 120
}

# ---------------------------------------------------------------- Ollama

resource "docker_container" "ollama" {
  name    = "ai-agent-framework-ollama"
  image   = docker_image.ollama.image_id
  restart = "unless-stopped"

  networks_advanced {
    name    = docker_network.agents.name
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
  wait_timeout = 180
}

# One-shot: downloads the model; terraform waits until the pull has finished.
resource "docker_container" "ollama_pull" {
  name       = "ai-agent-framework-ollama-pull"
  image      = docker_image.ollama.image_id
  entrypoint = ["ollama", "pull", var.ollama_model]
  env        = ["OLLAMA_HOST=http://ollama:11434"]
  attach     = true
  must_run   = false
  logs       = true

  networks_advanced {
    name = docker_network.agents.name
  }

  depends_on = [docker_container.ollama]
}

# ---------------------------------------------------------------- Flowise

resource "docker_container" "flowise" {
  name    = "ai-agent-framework-flowise"
  image   = docker_image.flowise.image_id
  restart = "unless-stopped"

  env = [
    "PORT=3000",
    "APP_URL=${var.app_url}",
    "DATABASE_TYPE=postgres",
    "DATABASE_HOST=postgres",
    "DATABASE_PORT=5432",
    "DATABASE_NAME=flowise",
    "DATABASE_USER=flowise",
    "DATABASE_PASSWORD=${var.postgres_password}",
    "FLOWISE_SECRETKEY_OVERWRITE=${var.flowise_secretkey_overwrite}",
    "JWT_AUTH_TOKEN_SECRET=${var.jwt_auth_token_secret}",
    "JWT_REFRESH_TOKEN_SECRET=${var.jwt_refresh_token_secret}",
    "EXPRESS_SESSION_SECRET=${var.express_session_secret}",
    "TOKEN_HASH_SECRET=${var.token_hash_secret}",
    "JWT_ISSUER=Flowise",
    "JWT_AUDIENCE=Flowise",
    "SECRETKEY_PATH=/home/node/.flowise",
    "BLOB_STORAGE_PATH=/home/node/.flowise/storage",
    "LOG_PATH=/home/node/.flowise/logs",
    "LOG_LEVEL=info",
    "DISABLE_FLOWISE_TELEMETRY=true",
  ]

  networks_advanced {
    name    = docker_network.agents.name
    aliases = ["flowise"]
  }

  ports {
    internal = 3000
    external = var.flowise_port
    ip       = "127.0.0.1"
  }

  # Home directory of the image's non-root user (uid 1000), so the volume is writable.
  volumes {
    volume_name    = docker_volume.flowise_data.name
    container_path = "/home/node"
  }

  healthcheck {
    test         = ["CMD", "curl", "-fsS", "http://localhost:3000/api/v1/ping"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 30
    start_period = "30s"
  }

  wait         = true
  wait_timeout = 300

  depends_on = [docker_container.postgres, docker_container.ollama]
}

# One-shot: creates the owner account so the instance cannot be claimed by the first visitor.
resource "docker_container" "flowise_setup" {
  name       = "ai-agent-framework-flowise-setup"
  image      = docker_image.flowise.image_id
  entrypoint = ["node", "-e", local.setup_script]
  attach     = true
  must_run   = false
  logs       = true

  env = [
    "FLOWISE_ADMIN_NAME=${var.flowise_admin_name}",
    "FLOWISE_ADMIN_EMAIL=${var.flowise_admin_email}",
    "FLOWISE_ADMIN_PASSWORD=${var.flowise_admin_password}",
  ]

  networks_advanced {
    name = docker_network.agents.name
  }

  depends_on = [docker_container.flowise]
}

# ---------------------------------------------------------------- outputs

output "flowise_url" {
  description = "Flowise UI and API"
  value       = "http://localhost:${var.flowise_port}"
}

output "ollama_url" {
  description = "Ollama API on the host"
  value       = "http://localhost:${var.ollama_port}"
}

output "ollama_url_for_flowise" {
  description = "Base URL to enter in Flowise's ChatOllama / Ollama nodes"
  value       = "http://ollama:11434"
}
