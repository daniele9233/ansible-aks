#!/bin/bash
set -e

source ~/ansible-env/bin/activate

pip install flask --quiet

cd "$(dirname "$(realpath "$0")")"

echo ""
echo "  AKS Rancher Dashboard"
echo "  ─────────────────────────────────────────────"
echo "  URL locale:     http://localhost:8080"
echo ""
echo "  Accesso da Windows (SSH tunnel):"
echo "  ssh -L 8080:localhost:8080 azureuser@10.207.201.136"
echo "  Poi apri: http://localhost:8080"
echo "  ─────────────────────────────────────────────"
echo ""

python app.py
