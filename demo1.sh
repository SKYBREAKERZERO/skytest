#!/usr/bin/env bash
set -euo pipefail
BASE="live/dev"

echo "Creating directories..."

mkdir -p "${BASE}/global"
mkdir -p "${BASE}/datalake"
mkdir -p "${BASE}/governance"
mkdir -p "${BASE}/monitoring"
echo "Creating files..."
# global
touch "${BASE}/global/backend.tf"
touch "${BASE}/global/providers.tf"
touch "${BASE}/global/variables.tf"
touch "${BASE}/global/terraform.tfvars"
touch "${BASE}/global/main.tf"

# datalake
touch "${BASE}/datalake/backend.tf"
touch "${BASE}/datalake/providers.tf"
touch "${BASE}/datalake/variables.tf"
touch "${BASE}/datalake/terraform.tfvars"
touch "${BASE}/datalake/main.tf"
touch "${BASE}/datalake/outputs.tf"

# governance
touch "${BASE}/governance/backend.tf"
touch "${BASE}/governance/providers.tf"
touch "${BASE}/governance/main.tf"

# monitoring
touch "${BASE}/monitoring/backend.tf"
touch "${BASE}/monitoring/providers.tf"
touch "${BASE}/monitoring/main.tf"

# root files
touch "${BASE}/env.tfvars"
touch "${BASE}/versions.tf"
touch "${BASE}/Makefile"
touch "${BASE}/control.sh"

echo " Structure created successfully!"
if command -v tree >/dev/null 2>&1; then
  echo ""
  echo "Directory structure:"
  tree "${BASE}"
else
  echo "'tree' not installed. Run: sudo apt install tree"
fi
