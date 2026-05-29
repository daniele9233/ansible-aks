# Implementazioni future

Backlog tecnico del repo. Ogni voce è un miglioramento **identificato ma NON
ancora applicato**: serve a non perdere il contesto e a poter intervenire in
modo mirato quando si decide di farlo.

---

## 1. Variabilizzare la ingress class di Rancher

### Problema
La ingress class è gestita in modo **incoerente** tra i role:

- `roles/rancher_CAValid_install/tasks/00-rancher-CAValid-install.yml` la ha
  **hardcoded** a `"traefik"` in 4 punti:
  - riga 107 → `ingressClassName: "traefik"`   (blocco "first install")
  - riga 111 → `kubernetes.io/ingress.class: "traefik"`
  - riga 135 → `ingressClassName: "traefik"`   (blocco "upgrade")
  - riga 139 → `kubernetes.io/ingress.class: "traefik"`

- gli altri due role usano invece **una variabile** dedicata:
  - `roles/pgadmin_install/tasks/main.yml` → `{{ pgadmin_ingress_class }}` (righe 259, 263)
  - `roles/grafana_install/tasks/main.yml` → `{{ grafana_ingress_class }}` (righe 266, 270)

Le variabili `pgadmin_ingress_class` e `grafana_ingress_class` esistono già in
`group_vars/all/main.yml`; per Rancher **manca** l'equivalente.

### Perché è un problema
Se un domani si cambia Ingress Controller (es. da Traefik a nginx) o lo si
rinomina, pgAdmin e Grafana si adeguano cambiando una sola variabile, mentre
Rancher resta rotto finché non si edita il role a mano. È esattamente il tipo
di disallineamento che fa perdere tempo durante un upgrade.

### Fix proposta (comportamento invariato)
1. Aggiungere in `group_vars/all/main.yml`, nel blocco Rancher:
   ```yaml
   # Ingress class usata dall'Ingress di Rancher (coerente con pgadmin/grafana).
   rancher_ingress_class: "traefik"
   ```
2. In `00-rancher-CAValid-install.yml` sostituire i 4 letterali `"traefik"`
   (righe 107, 111, 135, 139) con `"{{ rancher_ingress_class }}"`.

Default identico al valore attuale → nessun cambiamento di comportamento sul
cluster esistente. Modifica sicura.

---

## 2. uid/gid e porte hardcoded nei role web (solo se si astrae un role generico)

Non sono errori: sono valori **legati all'immagine** e cambiano molto di rado.
Vanno toccati **solo** nel momento in cui si decide di unificare pgAdmin e
Grafana in un unico role parametrico `k8s_web_app` (vedi voce 4).

| Valore                    | File : riga                                  | Origine                  |
|---------------------------|----------------------------------------------|--------------------------|
| `runAsUser/fsGroup: 472`  | `roles/grafana_install/tasks/main.yml:141-143` | uid fisso immagine grafana |
| `runAsUser/fsGroup: 5050` | `roles/pgadmin_install/tasks/main.yml:140-142` | uid fisso immagine pgadmin |
| `containerPort: 3000`     | `roles/grafana_install/tasks/main.yml:150`     | porta interna grafana    |
| `containerPort: 80`       | `roles/pgadmin_install/tasks/main.yml:149`     | porta interna pgadmin    |

Finché i due role restano separati, lasciarli inline è la scelta più leggibile.

---

## 3. Falso allarme — dominio `*.app.iac-svil.almaviva.it` nei role

Annotato qui **per non risollevarlo** in futuro: il dominio compare nei role
solo in **commenti** e in **una stringa di `debug`**
(`rancher_CAValid` riga 190), mai in codice funzionante. Non è un problema
operativo, è solo cosmetico. Quando/se si parametrizza il dominio
(`app_domain_suffix`), basta aggiornare anche quei testi — ma non c'è urgenza.

---

## 4. Drift del namespace condiviso `monitoring` tra pgAdmin e Grafana

### Problema
`pgadmin_install` e `grafana_install` creano **lo stesso** namespace
`monitoring` (STEP 0), ma lo etichettano in **due modi diversi**:

- `roles/pgadmin_install/tasks/main.yml:37` → `labels: "{{ pgadmin_labels }}"`
  che espande a `{app: pgadmin, managed-by: iac}`
- `roles/grafana_install/tasks/main.yml:37-38` → `labels: { managed-by: "iac" }`
  (literal inline, senza `app:`)

Siccome entrambi i task usano `state: present`, **l'ultimo role eseguito
sovrascrive le label del namespace**: dopo `--tags grafana` il namespace perde
`app: pgadmin`; dopo `--tags pgadmin` ricompare. Le label "ballano" a seconda
dell'ordine di esecuzione.

In più, `app: pgadmin` su un namespace **condiviso** è semanticamente scorretto
(il namespace non appartiene a pgAdmin). La versione di Grafana
(`managed-by: iac` soltanto) è quella corretta per un namespace condiviso.

### Drift correlato (probe)
Stesso meccanismo, valori divergenti senza motivo documentato:

- readiness `initialDelaySeconds`: pgAdmin **30** (`pgadmin .../main.yml:182`)
  vs Grafana **20** (`grafana .../main.yml:189`)
- liveness `initialDelaySeconds`: pgAdmin **120** (`pgadmin .../main.yml:190`)
  vs Grafana **60** (`grafana .../main.yml:197`)

Potrebbe essere intenzionale (Grafana parte più in fretta), ma **dal codice non
si capisce**: è il tipo di divergenza nata dal copia-incolla che andrebbe o
documentata o uniformata.

### Fix proposta (comportamento invariato)
1. Uniformare la label del namespace condiviso a solo `managed-by: iac` in
   **entrambi** i role (allineare pgAdmin alla versione corretta di Grafana).
   Le label `app: <nome>` restano — giustamente — su Deployment/Service/PVC,
   non sul namespace.
2. Decidere e **documentare** se la differenza nei `initialDelaySeconds` è
   voluta; altrimenti allineare i due valori.

> Nota: questo drift è la dimostrazione concreta del costo della duplicazione
> tra i due role (pgAdmin/Grafana identici al ~90%). La soluzione strutturale è
> il role generico `k8s_web_app` — vedi sotto — da affrontare però solo alla
> **terza** app web ("Rule of Three"), non ora.

---

> Le voci di refactor più ampie (multi-cluster, role defaults, role generico
> `k8s_web_app`, CI/lint) sono fuori dallo scope di questo documento, che
> raccoglie nello specifico le **incoerenze e i valori hardcoded nei role**.
