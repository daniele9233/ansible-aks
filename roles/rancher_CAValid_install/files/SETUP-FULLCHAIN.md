# Setup fullchain certificato – *.app.iac-svil.almaviva.it

## Situazione attuale

| # | Certificato | Stato |
|---|------------|-------|
| 1 | `*.app.iac-svil.almaviva.it` (leaf) | ✅ Presente in `vault_cavalid.yml` |
| 2 | `AlmavivA Sub01` (intermediate) | ❌ Da aggiungere |
| 3 | Root CA AlmavivA | ❌ Da aggiungere |

Senza la catena completa il browser mostrerà warning TLS. Rancher parte comunque.

---

## Step 1 – Recuperare il certificato intermediate

Il certificato leaf contiene gli URL AIA per scaricare l'intermediate:

```bash
# Scarica intermediate in DER
curl -s "http://crl1.almaviva.it/aia/AlmavivA%20Sub01(1).crt" -o intermediate_sub01.crt

# Converti DER → PEM
openssl x509 -in intermediate_sub01.crt -inform DER -out intermediate_sub01.pem

# Verifica
openssl x509 -in intermediate_sub01.pem -noout -subject -issuer
# subject= CN=AlmavivA Sub01, DC=itmaster, DC=local
# issuer= ...Root CA...

# Stampa solo il PEM pulito
cat intermediate_sub01.pem
```

---

## Step 2 – Recuperare la Root CA

L'intermediate conterrà a sua volta i riferimenti AIA alla Root CA:

```bash
openssl x509 -in intermediate_sub01.pem -noout -text | grep -A4 "Authority Information"
```

Oppure ottienila dall'amministratore PKI AlmavivA / Active Directory Certificate Services:

```bash
# Alternativa: scarica dal CA AIA dell'intermediate
curl -s "http://<root-ca-aia-url>" -o rootca.crt
openssl x509 -in rootca.crt -inform DER -out rootca.pem
```

---

## Step 3 – Verificare la catena (MD5 chain check)

```bash
# MD5 modulus leaf cert (deve corrispondere alla chiave)
openssl x509 -in star.app.iac-svil.almaviva.it.pem -noout -modulus | openssl md5
# MD5= 87e255f74ee13283cf9817409230f4a5

# Verifica catena di fiducia
openssl verify -CAfile rootca.pem -untrusted intermediate_sub01.pem star.app.iac-svil.almaviva.it.pem
# Output atteso: star.app.iac-svil.almaviva.it.pem: OK
```

---

## Step 4 – Aggiornare vault_cavalid.yml con la catena completa

```bash
# Decrypt il file vault
ansible-vault decrypt group_vars/all/vault_cavalid.yml
```

Aprire `group_vars/all/vault_cavalid.yml` e modificare `vault_rancher_tls_crt_chain`.
Sostituire i blocchi placeholder con il contenuto reale:

```yaml
vault_rancher_tls_crt_chain: |
  -----BEGIN CERTIFICATE-----
  [contenuto leaf: *.app.iac-svil.almaviva.it -- già presente]
  -----END CERTIFICATE-----
  -----BEGIN CERTIFICATE-----
  [contenuto intermediate_sub01.pem]
  -----END CERTIFICATE-----
  -----BEGIN CERTIFICATE-----
  [contenuto rootca.pem]
  -----END CERTIFICATE-----
```

**IMPORTANTE**: nessuna riga vuota tra i blocchi `-----END-----` e `-----BEGIN-----`.

---

## Step 5 – Cifrare il vault (OBBLIGATORIO prima del commit)

```bash
# Cifra con ansible-vault
ansible-vault encrypt group_vars/all/vault_cavalid.yml

# Verifica che sia cifrato (prima riga deve essere $ANSIBLE_VAULT;...)
head -1 group_vars/all/vault_cavalid.yml
```

---

## Step 6 – Testare la chain completa

```bash
# Verifica finale della chain che verrà caricata su Kubernetes
openssl verify \
  -CAfile rootca.pem \
  -untrusted intermediate_sub01.pem \
  star.app.iac-svil.almaviva.it.pem

# Verifica che il secret venga creato correttamente (dry-run)
ansible-playbook site.yml --tags rancher_ca_valid --check --vault-password-file .vault_pass
```

---

## Riepilogo comandi in sequenza

```bash
curl -s "http://crl1.almaviva.it/aia/AlmavivA%20Sub01(1).crt" -o intermediate_sub01.crt
openssl x509 -in intermediate_sub01.crt -inform DER -out intermediate_sub01.pem
# [recupera rootca.pem dall'amministratore PKI]
openssl verify -CAfile rootca.pem -untrusted intermediate_sub01.pem star.app.iac-svil.almaviva.it.pem
ansible-vault decrypt group_vars/all/vault_cavalid.yml
# [aggiorna vault_rancher_tls_crt_chain con tutti e 3 i blocchi PEM]
ansible-vault encrypt group_vars/all/vault_cavalid.yml
ansible-playbook site.yml --tags rancher_ca_valid --vault-password-file .vault_pass
```
