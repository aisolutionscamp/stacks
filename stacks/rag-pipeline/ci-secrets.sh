#!/bin/sh
# Prints throwaway secrets for CI; appended to .env.
set -eu
echo "QDRANT_API_KEY=$(openssl rand -hex 32)"
echo "RAG_API_KEY=$(openssl rand -hex 32)"
