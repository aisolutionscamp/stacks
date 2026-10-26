#!/bin/sh
# Prints throwaway secrets for CI as KEY=value lines (appended to .env).
set -eu
for k in FLOWISE_SECRETKEY_OVERWRITE JWT_AUTH_TOKEN_SECRET JWT_REFRESH_TOKEN_SECRET \
  EXPRESS_SESSION_SECRET TOKEN_HASH_SECRET POSTGRES_PASSWORD; do
  echo "$k=$(openssl rand -hex 32)"
done
# Flowise requires upper case, lower case, digit and special character.
echo "FLOWISE_ADMIN_PASSWORD=Ci-9$(openssl rand -hex 12)"
