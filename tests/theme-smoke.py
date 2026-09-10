#!/usr/bin/env python3
"""Exercise the real QML adapter and file watches in an isolated Quickshell host."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).resolve().parents[1]
QS = sys.argv[1] if len(sys.argv) > 1 else shutil.which('qs') or shutil.which('quickshell')
if not QS:
    sys.exit('Quickshell is required')
PALETTE = dict(primary='#ee8844', primaryText='#111111', surface='#202020',
               surfaceVariant='#303030', text='#eeeeee', textMuted='#bbbbbb',
               outline='#666666', error='#ff4455', errorText='#110000', appearance='dark')
CONFIG = '''[accessibility]
ui_scale = 1.25

[shell]
font_family = "DejaVu Sans"
corner_radius_scale = 0.8

    [shell.animation]
    enabled = false
    speed = 2.0

[theme]
mode = "dark"
'''
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, sys
r = pathlib.Path(os.environ['THEME_TEST_ROOT'])
args = sys.argv[1:]
if args == ['config', 'export', 'full']:
    if (r / 'legacy').exists(): sys.exit(1)
    print((r / 'effective.toml').read_text())
    entry = r / 'config/noctalia/filesail.toml'
    if entry.exists() and not (r / 'excluded').exists(): print(entry.read_text())
elif args[:1] == ['msg']:
    entry = r / 'config/noctalia/filesail.toml'
    template = r / 'config/noctalia/templates/filesail.json'
    assert entry.exists() and template.exists(), 'Refresh ran before both writes completed'
    with (r / 'calls').open('a') as f: f.write(args[1] + '\\n')
    if args[1] == 'templates-apply':
        assert 'config-reload' in (r / 'calls').read_text()
        if (r / 'unavailable').exists(): sys.exit(1)
        output = r / 'config/filesail/theme.json'
        output.parent.mkdir(parents=True, exist_ok=True)
        output.with_suffix('.tmp').write_text((r / 'palette.json').read_text())
        output.with_suffix('.tmp').replace(output)
else: sys.exit(1)
'''


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(data))
    temp.replace(path)


class Host:
    def __init__(self, root):
        self.root = root
        self.env = dict(os.environ, XDG_CONFIG_HOME=str(root / 'config'),
                        XDG_STATE_HOME=str(root / 'state'), XDG_CACHE_HOME=str(root / 'cache'),
                        NOCTALIA_CONFIG_HOME=str(root / 'config'), NOCTALIA_STATE_HOME=str(root / 'state'),
                        THEME_TEST_ROOT=str(root), QT_QPA_PLATFORM='offscreen',
                        PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'])
        self.env.pop('NOCTALIA_CONFIG_DIR', None)
        (root / 'bin').mkdir()
        (root / 'bin/noctalia').write_text(MOCK)
        (root / 'bin/noctalia').chmod(0o755)
        self.shell = root / 'host'
        self.shell.mkdir()
        for name in ['qml', 'integrations']:
            (self.shell / name).symlink_to(SOURCE / name, target_is_directory=True)
        shutil.copy(SOURCE / 'tests/theme/shell.qml', self.shell / 'shell.qml')
        (root / 'effective.toml').write_text(CONFIG)
        write_json(root / 'palette.json', PALETTE)
        self.log = (root / 'host.log').open('w+')
        self.process = None

    def start(self):
        self.process = subprocess.Popen([QS, '-p', str(self.shell), '--no-color'], env=self.env,
                                        stdout=self.log, stderr=subprocess.STDOUT)
        self.wait(lambda s: bool(s), 'host startup')

    def call(self, method):
        result = subprocess.run([QS, 'ipc', '--path', str(self.shell), 'call', 'themeTest', method],
                                env=self.env, capture_output=True, text=True, timeout=4)
        return result.stdout.strip() if result.returncode == 0 else ''

    def wait(self, predicate, label):
        deadline = time.monotonic() + 8
        last = None
        while time.monotonic() < deadline:
            try:
                last = json.loads(self.call('snapshot'))
                if predicate(last): return last
            except (ValueError, subprocess.TimeoutExpired):
                pass
            time.sleep(.05)
        self.log.flush()
        raise AssertionError(f'{label}: {last}\n{(self.root / "host.log").read_text()}')

    def close(self):
        if self.process:
            self.process.terminate()
            try: self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()


def scenario(name, test):
    with tempfile.TemporaryDirectory(prefix='filesail-theme-') as temporary:
        host = Host(Path(temporary))
        try:
            test(host)
            log = (host.root / 'host.log').read_text()
            assert 'Configuration Loaded' in log
            assert not any(error in log for error in ['ReferenceError', 'TypeError', 'Binding loop', 'Failed to load configuration']), log
            print('PASS:', name)
        finally:
            host.close()


def live(host):
    host.start()
    host.wait(lambda s: s['loaded'] and s['primary'] == PALETTE['primary'] and not s['pending'], 'first-run registration and render')
    host.wait(lambda s: s['scale'] == 1.25 and s['animationFast'] == 0, 'settings after first TOML table')
    target = host.root / 'config/filesail/theme.json'
    light = dict(PALETTE, primary='#4488cc', surface='#fafafa', text='#111111', appearance='light')
    write_json(target, light)
    host.wait(lambda s: s['surface'] == '#fafafa' and s['appearance'] == 'light', 'live atomic palette replacement')
    target.write_text('{"primary":')
    host.call('refresh')
    time.sleep(.25)
    host.wait(lambda s: s['surface'] == '#fafafa', 'partial JSON retains last valid palette')
    write_json(target, dict(light, text='invalid'))
    host.call('refresh')
    time.sleep(.25)
    host.wait(lambda s: s['text'] == '#111111', 'invalid color rejects entire snapshot')
    write_json(target, dict(light, primary='#5588cc'))
    host.wait(lambda s: s['primary'] == '#5588cc', 'watch recovers after invalid writes')
    (host.root / 'effective.toml').write_text(CONFIG.replace('1.25', '1.0').replace('enabled = false', 'enabled = true'))
    calls = (host.root / 'calls').read_text()
    host.call('refresh')
    host.wait(lambda s: s['scale'] == 1 and s['animationFast'] == 75 and s['appearance'] == 'light', 'reset metrics; rendered appearance wins')
    assert (host.root / 'calls').read_text() == calls, 'Metric refresh must not rerender every app template'
    previous_changes = json.loads(host.call('snapshot'))['primaryChanges']
    write_json(target, dict(light, primary='#cc88ee'))
    snapshot = host.wait(lambda s: s['primary'] == '#cc88ee', 'animated palette reaches target')
    assert snapshot['primaryChanges'] > previous_changes + 1, 'Palette snapped instead of transitioning'
    target.unlink()
    host.call('refresh')
    host.wait(lambda s: s['primary'] == PALETTE['primary'], 'deleted output regenerated')


def recovery(host):
    write_json(host.root / 'config/filesail/theme.json', dict(PALETTE, primary='#000001'))
    (host.root / 'unavailable').touch()
    host.start()
    host.wait(lambda s: s['ready'] and s['pending'], 'unavailable Noctalia keeps retry pending')
    (host.root / 'unavailable').unlink()
    host.call('refresh')
    host.wait(lambda s: s['primary'] == PALETTE['primary'] and not s['pending'], 'recover and replace stale cache')


def disabled(host):
    entry = host.root / 'config/noctalia/filesail.toml'
    entry.parent.mkdir(parents=True)
    original = '[theme.templates.user.filesail]\ninput_path = "templates/filesail.json"\nenabled = false\n'
    entry.write_text(original)
    host.start()
    host.wait(lambda s: s['ready'] and not s['enabled'], 'disabled template')
    host.call('refresh')
    assert entry.read_text() == original
    assert not (host.root / 'calls').exists(), 'Disabled template triggered IPC'
    entry.write_text(original.replace('false', 'true'))
    host.call('refresh')
    host.wait(lambda s: s['loaded'], 'template re-enabled during session')


def legacy(host):
    (host.root / 'legacy').touch()
    keys = ['mPrimary', 'mOnPrimary', 'mSurface', 'mSurfaceVariant', 'mOnSurface', 'mOnSurfaceVariant', 'mOutline', 'mError', 'mOnError']
    write_json(host.root / 'config/noctalia/colors.json', dict(zip(keys, list(PALETTE.values())[:9])))
    write_json(host.root / 'config/noctalia/settings.json', {'general': {'scaleRatio': 1.5}, 'colorSchemes': {'darkMode': False}})
    host.start()
    host.wait(lambda s: s['primary'] == PALETTE['primary'] and s['scale'] == 1.5 and s['appearance'] == 'light', 'Noctalia 4 fallback')
    assert not (host.root / 'config/noctalia/filesail.toml').exists()


def declarative_disabled(host):
    # Noctalia may resolve this from an included, immutable profile. FileSail
    # must not shadow its opt-out by creating a new filesail.toml next to it.
    (host.root / 'effective.toml').write_text(CONFIG + '\n[theme.templates.user.filesail]\n'
                                             'input_path = "/store/filesail/template.json"\nenabled = false\n')
    host.start()
    host.wait(lambda s: s['ready'] and not s['enabled'], 'declarative opt-out')
    assert not (host.root / 'config/noctalia/filesail.toml').exists()
    assert not (host.root / 'config/noctalia/templates').exists()
    assert not (host.root / 'calls').exists()


for name, test in [('live updates and validation', live), ('late shell and stale cache', recovery),
                   ('opt-out and re-enable', disabled), ('Noctalia 4 compatibility', legacy),
                   ('declarative registration preserved', declarative_disabled)]:
    scenario(name, test)

# When installed, validate the shipped template against the real public CLI as
# well. Rendering uses a synthetic palette and isolated config, never the desktop.
noctalia = shutil.which('noctalia')
if noctalia:
    roles = ['primary', 'on_primary', 'surface', 'surface_variant', 'on_surface',
             'on_surface_variant', 'outline', 'error', 'on_error']
    keys = list(PALETTE)[:-1]
    with tempfile.TemporaryDirectory(prefix='filesail-native-theme-') as directory:
        root = Path(directory)
        palettes = {mode: {role: '#%06x' % (base + sign * i * 0x101010)
                           for i, role in enumerate(roles)}
                    for mode, base, sign in [('dark', 0x222222, 1), ('light', 0xeeeeee, -1)]}
        write_json(root / 'palette.json', palettes)
        env = dict(os.environ, NOCTALIA_CONFIG_HOME=directory, NOCTALIA_STATE_HOME=directory,
                   XDG_CACHE_HOME=directory, XDG_DATA_HOME=directory)
        for mode in palettes:
            subprocess.run([noctalia, 'theme', '--theme-json', str(root / 'palette.json'),
                            '--default-mode', mode, '--render',
                            str(SOURCE / 'integrations/noctalia/theme-template.json') + ':' + str(root / 'result.json')],
                           env=env, check=True, capture_output=True, timeout=10)
            result = json.loads((root / 'result.json').read_text())
            assert result == dict(zip(keys, palettes[mode].values()), appearance=mode), result
            print('PASS: native Noctalia template renderer (' + mode + ')')
