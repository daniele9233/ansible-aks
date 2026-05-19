#!/bin/bash
# Rimuove Rancher e tutti i suoi componenti dal cluster AKS.
# NON tocca il cluster AKS stesso (nodi, networking, control plane).
# Copre entrambe le modalita': rancher_self_signed e rancher_ca_valid.

set -x

echo "=== INIZIO DISINSTALLAZIONE RANCHER ==="

# 1. Rancher
echo "Rimozione di Rancher e del namespace cattle-system..."
helm uninstall rancher --namespace cattle-system 2>/dev/null || echo "Rancher gia' rimosso."
kubectl delete namespace cattle-system --ignore-not-found

# 2. Traefik (solo rancher_ca_valid)
echo "Rimozione di Traefik e del namespace traefik..."
helm uninstall traefik --namespace traefik 2>/dev/null || echo "Traefik gia' rimosso."
kubectl delete namespace traefik --ignore-not-found

# 3. Cert-Manager (solo rancher_self_signed)
echo "Rimozione di Cert-Manager e del namespace cert-manager..."
helm uninstall cert-manager --namespace cert-manager 2>/dev/null || echo "Cert-Manager gia' rimosso."
kubectl delete namespace cert-manager --ignore-not-found

# 4. CRD cert-manager
echo "Rimozione dei CRD di cert-manager..."
kubectl delete crd \
  certificaterequests.cert-manager.io \
  certificates.cert-manager.io \
  challenges.acme.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io \
  --ignore-not-found

# 5. CRD Rancher / Cattle / Fleet
echo "Rimozione dei CRD di Rancher/Cattle/Fleet..."
kubectl get crds | grep -E 'cattle|rancher|fleet' | awk '{print $1}' | xargs -r kubectl delete crd

# 6. Repository Helm
echo "Rimozione dei repository Helm..."
helm repo remove rancher-stable 2>/dev/null || echo "Repository rancher-stable non presente."
helm repo remove jetstack      2>/dev/null || echo "Repository jetstack non presente."
helm repo remove traefik       2>/dev/null || echo "Repository traefik non presente."

echo "=== DISINSTALLAZIONE COMPLETATA ==="
