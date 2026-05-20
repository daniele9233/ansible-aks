#!/bin/bash
# Rimuove COMPLETAMENTE Rancher e i suoi componenti dal cluster AKS.
# NON tocca il cluster AKS (nodi, networking, control plane, kube-system).
# Copre entrambe le modalita': rancher_self_signed e rancher_ca_valid.
#
# Idempotente: puo' essere rilanciato a freddo o dopo un install fallito.
# Risolve gli stuck "CRD/namespace in Terminating" rimuovendo i finalizer
# (Rancher e' gia' down -> i finalizer non vengono piu' processati).
#
# Dipendenze: kubectl, helm, jq.

log() { printf "\n=== %s ===\n" "$*"; }

# Pattern: tutti i CRD installati da Rancher e da Fleet finiscono in .cattle.io
RANCHER_CRD_REGEX='\.cattle\.io$'
CERTMGR_CRD_REGEX='\.cert-manager\.io$'

# Namespace gestiti da Rancher / Traefik / cert-manager
RANCHER_NAMESPACES=(
  cattle-system
  cattle-fleet-system
  cattle-fleet-local-system
  cattle-fleet-clusters-system
  cattle-impersonation-system
  cattle-global-data
  cattle-global-nt
  fleet-system
  fleet-default
  fleet-local
  local
  traefik
  cert-manager
)

# Pattern dinamico: cattura anche i namespace creati da extension/installazioni
# non incluse nella lista sopra (Rancher Turtles, UI plugins, CAPI, cluster-fleet-local-<hash>, ecc.)
# Esempi catturati: cattle-turtles-system, cattle-ui-plugin-system, cattle-capi-system,
# cattle-local-user-passwords, cluster-fleet-local-local-1a3d67d0a899.
RANCHER_NS_PATTERN='^(cattle-|cluster-fleet-|fleet-|local$|traefik$|cert-manager$)'

log "INIZIO DISINSTALLAZIONE RANCHER"

# ---------------------------------------------------------------------------
# 1. Helm uninstall (Rancher, Traefik, cert-manager)
# ---------------------------------------------------------------------------
log "1/9 Helm uninstall"
helm uninstall rancher      -n cattle-system 2>/dev/null || echo "  - rancher: gia' rimosso"
helm uninstall traefik      -n traefik       2>/dev/null || echo "  - traefik: gia' rimosso"
helm uninstall cert-manager -n cert-manager  2>/dev/null || echo "  - cert-manager: gia' rimosso"

# ---------------------------------------------------------------------------
# 2. Attendi che i pod Rancher escano (evita race con i finalizer)
# ---------------------------------------------------------------------------
log "2/9 Attendo terminazione pod Rancher (max 60s)"
kubectl wait --for=delete pod -n cattle-system -l app=rancher --timeout=60s 2>/dev/null \
  || echo "  - nessun pod o timeout (procedo)"

# ---------------------------------------------------------------------------
# 3. Rimuovi i finalizer da TUTTE le CR Rancher (sotto *.cattle.io)
#    Senza Rancher running i finalizer restano e bloccano la cancellazione.
# ---------------------------------------------------------------------------
log "3/9 Rimozione finalizer dalle Custom Resource Rancher"
for api in $(kubectl api-resources --verbs=list -o name 2>/dev/null | grep -E "$RANCHER_CRD_REGEX"); do
  # Namespaced
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    ns="${line%%/*}"
    name="${line##*/}"
    kubectl patch "$api" "$name" -n "$ns" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done < <(kubectl get "$api" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)

  # Cluster-scoped (namespace vuoto -> il jsonpath di sopra le salta)
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    kubectl patch "$api" "$name" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done < <(kubectl get "$api" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
done

# ---------------------------------------------------------------------------
# 4. Rimuovi i CRD Rancher (prima togli i finalizer del CRD stesso, poi delete con wait)
# ---------------------------------------------------------------------------
log "4/9 Rimozione CRD Rancher (*.cattle.io)"
mapfile -t rancher_crds < <(kubectl get crd -o name 2>/dev/null | grep -E "$RANCHER_CRD_REGEX")
if [ ${#rancher_crds[@]} -gt 0 ]; then
  for crd in "${rancher_crds[@]}"; do
    kubectl patch "$crd" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl delete "${rancher_crds[@]}" --wait=true --timeout=180s --ignore-not-found 2>&1 \
    | grep -v 'not found' || true
else
  echo "  - nessun CRD .cattle.io presente"
fi

# ---------------------------------------------------------------------------
# 5. Rimuovi i CRD cert-manager
# ---------------------------------------------------------------------------
log "5/9 Rimozione CRD cert-manager"
mapfile -t cm_crds < <(kubectl get crd -o name 2>/dev/null | grep -E "$CERTMGR_CRD_REGEX")
if [ ${#cm_crds[@]} -gt 0 ]; then
  for crd in "${cm_crds[@]}"; do
    kubectl patch "$crd" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  done
  kubectl delete "${cm_crds[@]}" --wait=true --timeout=60s --ignore-not-found 2>&1 \
    | grep -v 'not found' || true
else
  echo "  - nessun CRD cert-manager presente"
fi

# ---------------------------------------------------------------------------
# 6. Namespace: delete + sblocco di quelli stuck in Terminating
#    La lista hardcoded viene estesa dinamicamente con i ns che matchano
#    RANCHER_NS_PATTERN (catturando cosi' extension e ns con suffisso random).
# ---------------------------------------------------------------------------
log "6/10 Rimozione namespace Rancher / Traefik / cert-manager"

# Estendi RANCHER_NAMESPACES con i ns dinamici che matchano il pattern
while IFS= read -r dyn_ns; do
  [ -z "$dyn_ns" ] && continue
  if [[ ! " ${RANCHER_NAMESPACES[*]} " =~ " ${dyn_ns} " ]]; then
    RANCHER_NAMESPACES+=("$dyn_ns")
    echo "  + scoperto ns dinamico: $dyn_ns"
  fi
done < <(kubectl get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -E "$RANCHER_NS_PATTERN")

for ns in "${RANCHER_NAMESPACES[@]}"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    echo "  - $ns: delete"
    kubectl delete ns "$ns" --wait=false --ignore-not-found >/dev/null
  fi
done

echo "  Attendo 10s per la terminazione..."
sleep 10

# Forza l'uscita dei namespace stuck (rimuove i finalizer via API finalize)
for ns in "${RANCHER_NAMESPACES[@]}"; do
  phase=$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
  if [ "$phase" = "Terminating" ]; then
    echo "  - $ns stuck in Terminating, rimozione forzata finalizer"
    kubectl get ns "$ns" -o json 2>/dev/null \
      | jq '.spec.finalizers = [] | .metadata.finalizers = []' \
      | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
  fi
done

# ---------------------------------------------------------------------------
# 7. Force-delete dei pod fantasma rimasti nei ns Rancher/Fleet/Traefik
#    Quando i namespace vengono cancellati via finalizer forzato, i pod
#    possono restare elencati con status Terminating (orfani senza padrone).
#    Match per pattern: indipendente dai nomi/hash, idempotente.
# ---------------------------------------------------------------------------
log "7/10 Force-delete pod fantasma (pattern-based)"
ghost_count=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  ns=$(echo "$line" | awk '{print $1}')
  pod=$(echo "$line" | awk '{print $2}')
  kubectl delete pod -n "$ns" "$pod" --force --grace-period=0 >/dev/null 2>&1 \
    && ghost_count=$((ghost_count + 1)) || true
done < <(kubectl get pods -A --no-headers 2>/dev/null \
           | awk -v p="$RANCHER_NS_PATTERN" '$1 ~ p {print $1, $2}')

if [ "$ghost_count" -gt 0 ]; then
  echo "  Pod fantasma rimossi: $ghost_count"
else
  echo "  - nessun pod fantasma trovato"
fi

# ---------------------------------------------------------------------------
# 8. Cluster-wide leftovers (ClusterRole, ClusterRoleBinding, Webhook, APIService)
# ---------------------------------------------------------------------------
log "8/10 Pulizia cluster-wide (ClusterRole/Binding, Webhook, APIService)"

LEFTOVER_REGEX='cattle|rancher|fleet|cert-manager|traefik'

# ClusterRoleBindings: match per nome E per roleRef.name
# (cattura CRB con nome random tipo "request-<hash>-content" che punta a "fleet-content")
for crb in $(kubectl get clusterrolebinding -o name 2>/dev/null); do
  crb_name=$(echo "$crb" | sed 's|.*/||')
  role_ref=$(kubectl get "$crb" -o jsonpath='{.roleRef.name}' 2>/dev/null)
  if echo "$crb_name $role_ref" | grep -qE "$LEFTOVER_REGEX"; then
    kubectl delete "$crb" --ignore-not-found >/dev/null 2>&1 || true
  fi
done

kubectl get clusterrole -o name 2>/dev/null \
  | grep -E "$LEFTOVER_REGEX" \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true

kubectl get mutatingwebhookconfiguration -o name 2>/dev/null \
  | grep -E "$LEFTOVER_REGEX" \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true

kubectl get validatingwebhookconfiguration -o name 2>/dev/null \
  | grep -E "$LEFTOVER_REGEX" \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true

# APIServices aggregati: Rancher (.cattle.io), Traefik (.traefik.io / hub.traefik.io), Fleet
kubectl get apiservice -o name 2>/dev/null \
  | grep -E '\.(cattle|traefik|fleet)\.io$|hub\.traefik\.io$' \
  | xargs -r kubectl delete --ignore-not-found >/dev/null 2>&1 || true

echo "  Cluster-wide leftovers rimossi."

# ---------------------------------------------------------------------------
# 9. Repository Helm locali
# ---------------------------------------------------------------------------
log "9/10 Rimozione repository Helm"
helm repo remove rancher-stable 2>/dev/null || echo "  - rancher-stable: non presente"
helm repo remove jetstack       2>/dev/null || echo "  - jetstack: non presente"
helm repo remove traefik        2>/dev/null || echo "  - traefik: non presente"

# ---------------------------------------------------------------------------
# 10. Verifica finale
# ---------------------------------------------------------------------------
log "10/10 Verifica finale"
remaining_crds=$(kubectl get crd 2>/dev/null | grep -cE "$RANCHER_CRD_REGEX|$CERTMGR_CRD_REGEX" || true)
remaining_ns=$(kubectl get ns -o name 2>/dev/null | sed 's|namespace/||' \
                | grep -cE "$RANCHER_NS_PATTERN" || true)
remaining_pods=$(kubectl get pods -A --no-headers 2>/dev/null \
                  | awk -v p="$RANCHER_NS_PATTERN" '$1 ~ p' \
                  | wc -l)

echo "  CRD Rancher/cert-manager residui: ${remaining_crds}"
echo "  Namespace Rancher/Fleet residui:  ${remaining_ns}"
echo "  Pod fantasma residui:             ${remaining_pods}"

if [ "$remaining_crds" -eq 0 ] && [ "$remaining_ns" -eq 0 ] && [ "$remaining_pods" -eq 0 ]; then
  log "DISINSTALLAZIONE COMPLETATA - cluster AKS intatto"
  echo "Per reinstallare: ansible-playbook site.yml --tags rancher_ca_valid --ask-vault-pass"
else
  log "DISINSTALLAZIONE COMPLETATA con residui"
  echo "Alcune risorse sono ancora presenti. Diagnostica:"
  echo "  kubectl get crd  | grep -E '${RANCHER_CRD_REGEX}|${CERTMGR_CRD_REGEX}'"
  echo "  kubectl get ns   | grep -E '${RANCHER_NS_PATTERN}'"
  echo "  kubectl get pods -A | grep -E '${RANCHER_NS_PATTERN}'"
  echo "Rilancia lo script. Se persiste, rimuovi a mano i finalizer del singolo oggetto."
fi
