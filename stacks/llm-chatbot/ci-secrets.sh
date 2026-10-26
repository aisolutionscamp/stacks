#!/bin/sh
# Prints throwaway secrets for CI; CI appends them to .env.
set -eu
echo "WEBUI_SECRET_KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
