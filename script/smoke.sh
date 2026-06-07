#!/usr/bin/env bash
# Hits each /v1 endpoint against a running server and pretty-prints the response.
# Usage: BASE=http://localhost:3000 script/smoke.sh
set -euo pipefail
BASE="${BASE:-http://localhost:3000}"

echo "== GET /v1/openapi.json (truncated) =="
curl -s "$BASE/v1/openapi.json" | head -c 300; echo

for path in \
  "/v1/categories" \
  "/v1/products" \
  "/v1/inventory_items" \
  "/v1/inventory" \
  "/v1/inventory?include_empty=true" \
  "/v1/inventory/low_stock" \
  "/v1/inventory/near_expiration" \
  "/v1/inventory/near_expiration?days=7"
do
  echo
  echo "== GET $path =="
  curl -sf "$BASE$path" | ruby -rjson -e 'puts JSON.pretty_generate(JSON.parse($stdin.read))' | head -40
done
