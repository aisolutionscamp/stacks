#!/bin/sh
# Prints generated secrets for CI. CI appends the output to .env.
set -eu
echo "API_KEY=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
