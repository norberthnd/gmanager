#!/usr/bin/env bash
# Start local Ghost 6 and prepare it for tests. Writes tools/ghost-dev/.env.
set -euo pipefail
cd "$(dirname "$0")"
docker compose up -d
python3 setup.py
echo "Ghost admin: http://localhost:2368/ghost  (owner@example.com / atelier-dev-password-1)"
