#!/usr/bin/env bash
set -euo pipefail

BASE="live/dev"

echo " Creating directories..."

mkdir -p "${BASE}"/{global,datalake,governance,monitoring}

echo " Creating files..."

# global
touch "${BASE}/global/"{backend.tf,providers.tf,variables.tf,terraform.tfvars,main.tf}

# datalake
touch "${BASE}/datalake/"{backend.tf,providers.tf,variables.tf,terraform.tfvars,main.tf,outputs.tf}

# governance
touch "${BASE}/governance/"{backend.tf,providers.tf,main.tf}

# monitoring
touch "${BASE}/monitoring/"{backend.tf,providers.tf,main.tf}

# root files
touch "${BASE}/"{env.tfvars,versions.tf,Makefile,control.sh}

echo " Structure created successfully!"

if command -v tree >/dev/null 2>&1; then
  echo ""
  echo " Directory structure:"
  tree "${BASE}"
else
  echo " Install tree: sudo apt install tree"
fi
