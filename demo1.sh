#!/bin/bash
set -e

BASE=live/dev
echo "Creating directories..."
mkdir -p $BASE/{global,datalake,governance,monitoring}
echo "Creating files..."
touch $BASE/global/{backend.tf,providers.tf,variables.tf,terraform.tfvars,main.tf}
touch $BASE/datalake/{backend.tf,providers.tf,variables.tf,terraform.tfvars,main.tf,outputs.tf}
touch $BASE/governance/{backend.tf,providers.tf,main.tf}
touch $BASE/monitoring/{backend.tf,providers.tf,main.tf}
touch $BASE/{env.tfvars,versions.tf,Makefile,control.sh}
echo "OK."