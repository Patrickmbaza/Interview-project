#!/usr/bin/env bash
set -euo pipefail

url="${1:?Usage: scripts/verify.sh http://host}"
curl --fail --silent --show-error "${url%/}/health" | grep -q 'healthy'
echo "Health check passed: ${url%/}/health"
