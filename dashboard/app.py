from flask import Flask, request, jsonify, render_template
import subprocess
import threading
import tempfile
import shlex
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
    'dryrun_ca_valid':        {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_ca_valid',    '--check', '--diff'],            'needs_vault': True},
    'dryrun_self':            {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_self_signed', '--check', '--diff'],            'needs_vault': True},
    'dryrun_aks_static_pv':   {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'aks_static_pv',       '--check', '--diff'],            'needs_vault': True},
    'dryrun_pgadmin':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'pgadmin',             '--check', '--diff'],            'needs_vault': True},
    'deploy_ca_valid':        {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_ca_valid'],                                    'needs_vault': True},
    'deploy_self':            {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'rancher_self_signed'],                                 'needs_vault': True},
    'deploy_aks_static_pv':   {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'aks_static_pv'],                                       'needs_vault': True},
    'deploy_pgadmin':         {'exe': 'ansible-playbook', 'args': ['site.yml', '--tags', 'pgadmin'],                                             'needs_vault': True},
    'uninstall':              {'exe': 'bash',             'args': ['uninstall-rancher.sh'],                                                      'needs_vault': False},
}


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


if __name__ == '__main__':
    app.run(host='127.0.0.1', port=8080, debug=False, threaded=True)
