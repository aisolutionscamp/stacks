# AI Solutions Camp stacks

Self-hosted AI stacks you can run on your own infrastructure. Every stack ships the same set of deployment options and is tested in CI:

| Stack | What it runs | Compose | Helm | Terraform (Docker) | Terraform (AWS) |
|---|---|---|---|---|---|
| [RAG Pipeline](stacks/rag-pipeline) | Retrieval-augmented generation over your documents | ✓ | ✓ | ✓ | ✓ |
| [LLM Chatbot](stacks/llm-chatbot) | Private chat UI with local models | ✓ | ✓ | ✓ | ✓ |
| [Embedding Service](stacks/embedding-service) | Text embeddings over HTTP | ✓ | ✓ | ✓ | ✓ |
| [AI Agent Framework](stacks/ai-agent-framework) | Visual builder for LLM agents | ✓ | ✓ | ✓ | ✓ |

Each stack is also listed with a guided setup on [aisolutionscamp.io/stacks](https://aisolutionscamp.io/stacks).

## Layout

```
stacks/<slug>/
  README.md               documentation for the stack
  stack.json              catalog metadata (name, description, tags, env variables, ...)
  compose.yaml            Docker Compose deployment
  .env.example            settings, copy to .env
  smoke-test.sh           starts nothing, only checks a running stack (used by CI)
  helm/install.sh         Helm commands
  helm/values.yaml        values for the chart
  terraform/local/main.tf Terraform with the Docker provider (single machine)
  terraform/aws/main.tf   Terraform for AWS
  quickstart/*.md         short setup notes per deployment option
```

## What CI checks

- `docker compose config` for every stack, then `docker compose up` and `smoke-test.sh` against the running containers
- `helm lint` / `helm template` (or the chart install command for upstream charts)
- `terraform fmt -check` and `terraform validate` for both Terraform variants

The AWS Terraform is validated but not applied in CI, because applying it creates billable resources. Review it and run `terraform plan` in your own account first.

## License

MIT
