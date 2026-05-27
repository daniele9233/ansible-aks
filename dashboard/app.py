from flask import Flask, request, jsonify, render_template
import subprocess
import threading
import tempfile
import shlex
import shutil
import json
import time
import re
import os

app = Flask(__name__)

ANSIBLE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
VENV = os.path.expanduser('~/ansible-env')

_job_lock = threading.Lock()
_job_state = {
    'status': 'idle',  # idle | running | success | failed
    'output': [],
}

COMMANDS = {
    'vault_main':             {'exe': 'ansible-vault',    'args': ['view', 'group_vars/all/vault.yml'],                                          'needs_vault': True},
    'vault_cavalid':          {'exe': 'ansible-vault',    'args': ['view', 'group_vars/all/vault_cavalid.yml'],                                  'needs_vault': True},
    'vault_storage':          {'exe': 'ansible-vault',    'args': ['view', 'group_vars/all/vault_storage.yml'],                                  'needs_vault': True},
    'vault_pgadmin':          {'exe': 'ansible-vault',    'args': ['view', 'group_vars/all/vault_pgadmin.yml'],                                  'needs_vault': True},
    'vault_grafana':          {'exe': 'ansible-vault',    'args': ['view', 'group_vars/all/vault_grafana.yml'],                                  'needs_vault': True},
    'dryrun_all':             {'exe': 'ansible-playbook', 'args': ['site.yml',              '--check', '--diff'],                              'needs_vault': True},
    'dryrun_ca_valid':        {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_ca_valid', '--check', '--diff'],               'needs_vault': True},
    'dryrun_self':            {'exe': 'ansible-playbook', 'args': ['site-self-signed.yml',  '--check', '--diff'],                              'needs_vault': True},
    'dryrun_aks_static_pv':   {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'aks_static_pv',    '--check', '--diff'],               'needs_vault': True},
    'dryrun_pgadmin':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'pgadmin',          '--check', '--diff'],               'needs_vault': True},
    'dryrun_grafana':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'grafana',          '--check', '--diff'],               'needs_vault': True},
    'deploy_all':             {'exe': 'ansible-playbook', 'args': ['site.yml'],                                                                  'needs_vault': True},
    'deploy_ca_valid':        {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_ca_valid'],                                    'needs_vault': True},
    'deploy_self':            {'exe': 'ansible-playbook', 'args': ['site-self-signed.yml'],                                                      'needs_vault': True},
    'deploy_aks_static_pv':   {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'aks_static_pv'],                                       'needs_vault': True},
    'deploy_pgadmin':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'pgadmin'],                                             'needs_vault': True},
    'deploy_grafana':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'grafana'],                                             'needs_vault': True},
    'uninstall':              {'exe': 'bash',             'args': ['uninstall-rancher.sh'],                                                      'needs_vault': False},
    'uninstall_pgadmin':      {'exe': 'bash',             'args': ['uninstall-pgadmin.sh'],                                                      'needs_vault': False},
    'uninstall_grafana':      {'exe': 'bash',             'args': ['uninstall-grafana.sh'],                                                      'needs_vault': False},
}

# Nome PVC valido in Kubernetes: lowercase alfanumerici + '-' e '.'
# (RFC 1123 subdomain, 253 char max). Usato per validare i nomi PV passati
# dal client all'endpoint /api/disks/delete.
_K8S_NAME_RE = re.compile(r'^[a-z0-9]([a-z0-9.\-]{0,251}[a-z0-9])?$')


def _run(cmd_info, vault_password):
    vault_pass_file = None
    try:
        env = os.environ.copy()
        env['VIRTUAL_ENV'] = VENV
        env['PATH'] = f'{VENV}/bin:' + env.get('PATH', '')
        env.pop('PYTHONHOME', None)
        env['ANSIBLE_FORCE_COLOR'] = '1'
        env['PYTHONUNBUFFERED'] = '1'

        cmd_parts = [cmd_info['exe']] + list(cmd_info['args'])

        if vault_password:
            tf = tempfile.NamedTemporaryFile(mode='w', suffix='.vaultpass', delete=False)
            tf.write(vault_password)
            tf.close()
            vault_pass_file = tf.name
            cmd_parts += ['--vault-password-file', vault_pass_file]

        quoted = ' '.join(shlex.quote(p) for p in cmd_parts)
        shell_cmd = (
            f'source {VENV}/bin/activate'
            f' && printf "\\033[2m[venv] activated: %s\\n[venv] python:    %s\\033[0m\\n" "$VIRTUAL_ENV" "$(which python)"'
            f' && exec {quoted}'
        )

        proc = subprocess.Popen(
            ['bash', '-c', shell_cmd],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
            cwd=ANSIBLE_DIR,
            bufsize=1,
            universal_newlines=True,
        )

        for line in iter(proc.stdout.readline, ''):
            _job_state['output'].append(line.rstrip('\n'))

        proc.wait()
        _job_state['status'] = 'success' if proc.returncode == 0 else 'failed'

    except Exception as exc:
        _job_state['output'].append(f'[ERRORE INTERNO] {exc}')
        _job_state['status'] = 'failed'

    finally:
        if vault_pass_file:
            try:
                os.unlink(vault_pass_file)
            except OSError:
                pass
        _job_lock.release()


@app.route('/api/file')
def api_file():
    rel = request.args.get('path', '')
    full = os.path.normpath(os.path.join(ANSIBLE_DIR, rel))
    ansible_root = os.path.normpath(ANSIBLE_DIR)
    if full != ansible_root and not full.startswith(ansible_root + os.sep):
        return jsonify({'error': 'Path non consentito'}), 403
    try:
        with open(full, 'r', encoding='utf-8') as f:
            return jsonify({'content': f.read(), 'path': rel})
    except FileNotFoundError:
        return jsonify({'error': 'File non trovato'}), 404
    except Exception as exc:
        return jsonify({'error': str(exc)}), 500


@app.route('/')
def index():
    return render_template('index.html')


@app.route('/api/output')
def api_output():
    since = int(request.args.get('since', 0))
    lines = _job_state['output'][since:]
    return jsonify({
        'lines': lines,
        'total': len(_job_state['output']),
        'status': _job_state['status'],
    })


@app.route('/api/run', methods=['POST'])
def api_run():
    data = request.get_json(force=True) or {}
    action = data.get('action', '')
    vault_password = data.get('vault_password', '')

    if action not in COMMANDS:
        return jsonify({'error': 'Azione non valida'}), 400

    cmd_info = COMMANDS[action]
    if cmd_info['needs_vault'] and not vault_password:
        return jsonify({'error': 'Vault password obbligatoria per questa operazione'}), 400

    if not _job_lock.acquire(blocking=False):
        return jsonify({'error': 'Un job è già in esecuzione. Attendi il completamento.'}), 409

    _job_state['output'] = []
    _job_state['status'] = 'running'

    t = threading.Thread(
        target=_run,
        args=(cmd_info, vault_password if cmd_info['needs_vault'] else None),
        daemon=True,
    )
    t.start()

    return jsonify({'status': 'started'})


def _kubectl_env():
    """Env per chiamate kubectl sincrone (con venv attivo per kubeconfig coerente)."""
    env = os.environ.copy()
    env['VIRTUAL_ENV'] = VENV
    env['PATH'] = f'{VENV}/bin:' + env.get('PATH', '')
    env.pop('PYTHONHOME', None)
    return env


@app.route('/api/disks/list')
def api_disks_list():
    """Lista i PersistentVolume del cluster con metadati Azure Disk."""
    kubectl = shutil.which('kubectl') or 'kubectl'
    try:
        result = subprocess.run(
            [kubectl, 'get', 'pv', '-o', 'json'],
            capture_output=True, text=True, env=_kubectl_env(),
            cwd=ANSIBLE_DIR, timeout=15,
        )
        if result.returncode != 0:
            return jsonify({
                'error': 'kubectl get pv ha fallito',
                'detail': (result.stderr or result.stdout).strip()[:500],
            }), 502
        data = json.loads(result.stdout or '{}')
    except subprocess.TimeoutExpired:
        return jsonify({'error': 'kubectl timeout (>15s)'}), 504
    except json.JSONDecodeError as exc:
        return jsonify({'error': f'output kubectl non JSON: {exc}'}), 502
    except Exception as exc:
        return jsonify({'error': str(exc)}), 500

    items = []
    for pv in data.get('items', []) or []:
        meta = pv.get('metadata') or {}
        spec = pv.get('spec') or {}
        status = pv.get('status') or {}
        csi = spec.get('csi') or {}
        claim = spec.get('claimRef') or {}
        bound_pvc = None
        if claim.get('name'):
            bound_pvc = f"{claim.get('namespace') or '-'}/{claim.get('name')}"
        items.append({
            'name': meta.get('name'),
            'capacity': (spec.get('capacity') or {}).get('storage'),
            'accessModes': spec.get('accessModes') or [],
            'reclaimPolicy': spec.get('persistentVolumeReclaimPolicy'),
            'storageClass': spec.get('storageClassName') or '',
            'status': status.get('phase'),
            'boundPVC': bound_pvc,
            'csiDriver': csi.get('driver'),
            'volumeHandle': csi.get('volumeHandle'),
        })
    # Ordine stabile: prima i Released (sicuri da cancellare), poi Available,
    # poi Bound (rischiosi). All'interno: ordine alfabetico.
    phase_rank = {'Released': 0, 'Available': 1, 'Bound': 2}
    items.sort(key=lambda x: (phase_rank.get(x.get('status') or '', 9), x.get('name') or ''))
    return jsonify({'items': items, 'count': len(items)})


def _kubectl(kubectl, env, args, timeout=15):
    """Esegue 'kubectl <args>' e ritorna (returncode, output_combinato_stripped)."""
    try:
        r = subprocess.run(
            [kubectl] + args,
            capture_output=True, text=True, env=env, cwd=ANSIBLE_DIR, timeout=timeout,
        )
        return r.returncode, ((r.stdout or '') + (r.stderr or '')).strip()
    except subprocess.TimeoutExpired:
        return -1, f'(kubectl timeout >{timeout}s)'
    except Exception as exc:
        return -2, str(exc)


def _delete_pv_robust(kubectl, env, name):
    """Cancella un PV in modo idempotente, forzando la rimozione dei finalizer
    se il PV resta stuck in Terminating. Casi tipici di stuck su Azure Disk:
      - kubernetes.io/pv-protection: PVC ancora presente
      - external-attacher/disk.csi.azure.com: volume ancora attached al nodo
      - external-provisioner/disk.csi.azure.com: AKS non riesce a deprovisionare
    Strategia: delete --wait=false -> poll 8s -> patch finalizers null -> poll 10s.
    """
    log_lines = []

    def pv_exists():
        c, o = _kubectl(kubectl, env,
                        ['get', 'pv', name, '--ignore-not-found',
                         '-o', 'jsonpath={.metadata.name}'])
        return c == 0 and o != ''

    # 1) Delete non-bloccante (l'API server accetta la richiesta e ritorna subito).
    code, out = _kubectl(kubectl, env,
                         ['delete', 'pv', name, '--ignore-not-found', '--wait=false'])
    if out:
        log_lines.append(out)
    if code != 0 and 'not found' not in out.lower():
        return {'name': name, 'ok': False, 'output': '\n'.join(log_lines)}

    # 2) Polling: aspetta fino a 8s che il PV sparisca da solo.
    for _ in range(4):
        time.sleep(2)
        if not pv_exists():
            return {'name': name, 'ok': True,
                    'output': '\n'.join(log_lines) or 'PV cancellato'}

    # 3) Ancora presente -> rimozione forzata dei finalizer (stesso pattern
    #    di uninstall-rancher.sh per i namespace stuck in Terminating).
    log_lines.append('PV stuck in Terminating, forzo rimozione finalizer')
    code, out = _kubectl(kubectl, env,
                         ['patch', 'pv', name, '--type=merge',
                          '-p', '{"metadata":{"finalizers":null}}'])
    if out:
        log_lines.append(out)

    # 4) Verifica finale (fino a 10s).
    for _ in range(5):
        time.sleep(2)
        if not pv_exists():
            return {'name': name, 'ok': True, 'output': '\n'.join(log_lines)}

    log_lines.append('PV ancora presente dopo rimozione finalizer (anomalo: '
                     'verifica con: kubectl get pv ' + name + ' -o yaml)')
    return {'name': name, 'ok': False, 'output': '\n'.join(log_lines)}


@app.route('/api/disks/delete', methods=['POST'])
def api_disks_delete():
    """Cancella i PersistentVolume selezionati (uno alla volta, riporta esito per nome).
    Usa _delete_pv_robust che gestisce i finalizer stuck (caso comune sui PV CSI
    Azure quando il PVC esiste ancora o il volume e' attached a un nodo)."""
    payload = request.get_json(force=True, silent=True) or {}
    names = payload.get('names')
    if not isinstance(names, list) or not names:
        return jsonify({'error': "Campo 'names' deve essere una lista non vuota"}), 400

    invalid = [n for n in names if not (isinstance(n, str) and _K8S_NAME_RE.match(n))]
    if invalid:
        return jsonify({'error': f'Nomi PV non validi: {invalid}'}), 400

    kubectl = shutil.which('kubectl') or 'kubectl'
    env = _kubectl_env()
    results = [_delete_pv_robust(kubectl, env, name) for name in names]
    return jsonify({'results': results})


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8080, debug=False, threaded=True)
