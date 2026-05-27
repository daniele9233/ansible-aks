#!/bin/bash
# Disinstalla pgAdmin 4 installato dal role pgadmin_install.
# Rimuove: Deployment, Service, Ingress, Secrets, PVC pvc-pgadmin nel
# namespace 'monitoring'. Cancella anche il namespace se resta vuoto.
# La PVC managed-csi ha reclaim policy Delete -> AKS rimuove anche il
# disco Azure sottostante automaticamente.
#
# Idempotente: puo' essere rilanciato a freddo o dopo un install fallito.
# NON tocca il cluster AKS, ne' altri namespace, ne' la PVC del disco
# statico (pvc-disco-aks-test-iac in 'default').
#
# Dipendenze: kubectl

set -uo pipefail

log() { printf "\n=== %s ===\n" "$*"; }

NS="monitoring"
APP_LABEL="app=pgadmin"

# Safety guard: lista namespace che lo script NON deve mai toccare.
# Difesa in profondita' contro modifiche future della variabile NS.
PROTECTED_NS=(
  kube-system
  kube-public
  kube-node-lease
  default
  gatekeeper-system
  azure-arc
  azure-extensions-usage-system
  aks-command
  calico-system
  tigera-operator
  app-routing-system
  cattle-system
  cattle-fleet-system
  cert-manager
  traefik
)

for protected in "${PROTECTED_NS[@]}"; do
  if [ "$NS" = "$protected" ]; then
    echo "ERRORE FATALE: namespace '$NS' e' protetto. Lo script si rifiuta di procedere."
    exit 2
  fi
done

log "INIZIO DISINSTALLAZIONE pgAdmin (namespace: $NS)"

# ---------------------------------------------------------------------------
# 1. Verifica esistenza del namespace
# ---------------------------------------------------------------------------
log "1/5 Verifica namespace $NS"
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo "  - namespace '$NS' non esiste, nulla da fare"
  exit 0
fi
echo "  - namespace '$NS' presente, procedo"

# ---------------------------------------------------------------------------
# 2. Delete delle risorse pgAdmin tramite label selector
#    (cattura tutto: Deployment, Service, Ingress, Secrets, PVC, Pod)
# ---------------------------------------------------------------------------
log "2/5 Delete risorse con label '$APP_LABEL' in $NS"
kubectl -n "$NS" delete deploy,svc,ingress,secret,pvc,pod \
  -l "$APP_LABEL" --ignore-not-found --wait=true --timeout=60s

# ---------------------------------------------------------------------------
# 3. Fallback per risorse non labellate (nomi noti del role)
# ---------------------------------------------------------------------------
log "3/5 Delete risorse pgAdmin per nome (fallback)"
kubectl -n "$NS" delete deploy   pgadmin              --ignore-not-found
kubectl -n "$NS" delete svc      pgadmin              --ignore-not-found
kubectl -n "$NS" delete ingress  pgadmin              --ignore-not-found
kubectl -n "$NS" delete secret   tls-pgadmin-ingress  --ignore-not-found
kubectl -n "$NS" delete secret   pgadmin-admin        --ignore-not-found
kubectl -n "$NS" delete pvc      pvc-pgadmin          --ignore-not-found

# ---------------------------------------------------------------------------
# 4. Attendi che la PVC venga effettivamente rimossa
#    (managed-csi: AKS deprovisiona il disco Azure -> qualche secondo)
# ---------------------------------------------------------------------------
log "4/5 Attendo deprovisioning del disco Azure (max 60s)"
for i in $(seq 1 12); do
  if ! kubectl -n "$NS" get pvc pvc-pgadmin >/dev/null 2>&1; then
    echo "  - PVC rimossa, disco Azure deprovisionato"
    break
  fi
  echo "  - tentativo $i/12, PVC ancora presente, attendo 5s"
  sleep 5
done

# ---------------------------------------------------------------------------
# 5. Cancella il namespace SOLO se vuoto (rispetta eventuali altri carichi)
# ---------------------------------------------------------------------------
log "5/5 Cancellazione namespace $NS (solo se vuoto)"
# Conta risorse residue, escludendo gli oggetti di sistema sempre presenti
remaining=$(kubectl -n "$NS" get all,pvc,secret,configmap,ingress --no-headers 2>/dev/null \
            | grep -vE 'kube-root-ca\.crt|default-token-' \
            | wc -l)

if [ "$remaining" -eq 0 ]; then
  echo "  - $NS vuoto, delete namespace"
  kubectl delete namespace "$NS" --ignore-not-found --wait=true --timeout=60s
else
  echo "  - $NS contiene altre $remaining risorse, lo lascio intatto"
  echo "    (per cancellarlo manualmente: kubectl delete namespace $NS)"
fi

log "DISINSTALLAZIONE pgAdmin COMPLETATA"
echo "Per reinstallare: ansible-playbook site.yml --tags pgadmin --ask-vault-pass"
