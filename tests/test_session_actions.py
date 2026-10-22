"""Exercise real helper scripts with fake executables; no session is affected."""
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class SessionActions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="power menu '")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        # A relocated plugin directory containing spaces and apostrophes.
        self.plugin = self.base / "plugin ' copy"
        shutil.copytree(REPO / 'bin', self.plugin / 'bin')
        self.env = {**os.environ, 'PATH': str(self.bin),
                    'HOME': str(self.base), 'XDG_STATE_HOME': str(self.base / 'state'),
                    'TEST_ROOT': str(self.base)}
        self.log = self.base / 'actions'
        for cmd in ('dirname', 'mkdir', 'date', 'cat', 'grep', 'rm'):
            (self.bin / cmd).symlink_to(shutil.which(cmd))
        self.stub('systemctl', '''
case "$*" in
  *list-timers*) /bin/cat "$TEST_ROOT/units" 2>/dev/null ;;
  *stop*) : ;;
esac
''')
        self.stub('systemd-run', '''
printf '%s\\n' "$@" > "$TEST_ROOT/scheduled"
[ "${FAIL_SCHEDULE:-0}" = 0 ] || exit 1
for arg in "$@"; do
 case "$arg" in --unit=*) printf '%s.timer\\n' "${arg#--unit=}" > "$TEST_ROOT/units" ;; esac
done
''')

    def stub(self, name, body):
        p = self.bin / name
        p.write_text('#!/bin/bash\n' + body)
        p.chmod(0o755)

    def omarchy(self, name, code=0):
        self.stub(name, f'printf "%s\\n" "{name} $*" >> "$TEST_ROOT/actions"\nexit {code}\n')

    def run_cmd(self, args, check=True):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=check)

    def helper(self, action, check=True):
        return self.run_cmd([str(self.plugin / 'bin/session-action'), action], check)

    def test_unified_preferred_for_all_actions(self):
        self.omarchy('omarchy-system')
        for action in ('logout', 'reboot', 'shutdown'):
            self.omarchy('omarchy-system-' + action)
            self.helper(action)
        self.assertEqual(self.log.read_text().splitlines(),
                         ['omarchy-system ' + a for a in ('logout', 'reboot', 'shutdown')])

    def test_legacy_only(self):
        for action in ('logout', 'reboot', 'shutdown'):
            self.omarchy('omarchy-system-' + action)
            self.helper(action)
        self.assertEqual(self.log.read_text().splitlines(),
                         ['omarchy-system-' + a + ' ' for a in ('logout', 'reboot', 'shutdown')])

    def test_failure_does_not_retry_legacy(self):
        self.omarchy('omarchy-system', 23)
        self.omarchy('omarchy-system-reboot')
        self.assertEqual(self.helper('reboot', check=False).returncode, 23)
        self.assertEqual(self.log.read_text(), 'omarchy-system reboot\n')

    def test_missing_and_invalid(self):
        self.assertEqual(self.helper('logout', check=False).returncode, 127)
        self.assertIn('no Omarchy command', self.helper('shutdown', check=False).stderr)
        self.assertEqual(self.helper('suspend', check=False).returncode, 2)
        self.assertEqual(self.run_cmd([str(self.plugin / 'bin/session-action'), 'reboot', 'extra'], False).returncode, 2)
        self.assertFalse(self.log.exists())

    def test_timer_execution_upgrade_status_and_cancel(self):
        for action in ('reboot', 'shutdown'):
            with self.subTest(action=action):
                timer = str(self.plugin / f'bin/{action}-timer')
                legacy = 'omarchy-system-' + action
                self.omarchy(legacy)
                armed = json.loads(self.run_cmd([timer, 'arm', '900']).stdout)
                self.assertTrue(armed['armed'])
                self.assertEqual(armed['remaining'], 900)
                scheduled = (self.base / 'scheduled').read_text().splitlines()
                self.assertIn('--on-active=900s', scheduled)
                self.assertIn('--unit=omarchy-' + action + '-timer', scheduled)
                self.assertIn('--setenv=PATH=' + self.env['PATH'], scheduled)
                self.assertEqual(scheduled[-2:], [str(self.plugin / 'bin/session-action'), action])
                self.assertFalse(self.log.exists())  # Arming must not execute.
                self.assertTrue(json.loads(self.run_cmd([timer, 'status']).stdout)['armed'])
                # Execute the captured service argv, first on old Omarchy.
                self.run_cmd(scheduled[-2:])
                self.assertEqual(self.log.read_text(), legacy + ' \n')
                self.log.unlink()
                (self.bin / legacy).unlink()
                self.omarchy('omarchy-system')
                self.run_cmd(scheduled[-2:])
                self.assertEqual(self.log.read_text(), 'omarchy-system ' + action + '\n')
                self.log.unlink()
                (self.bin / 'omarchy-system').unlink()
                self.assertFalse(json.loads(self.run_cmd([timer, 'cancel']).stdout)['armed'])
                self.assertFalse(json.loads(self.run_cmd([timer, 'status']).stdout)['armed'])

    def test_timer_invalid_and_schedule_failure(self):
        for action in ('reboot', 'shutdown'):
            timer = str(self.plugin / f'bin/{action}-timer')
            for seconds in ('0', '-1', '31536001', 'bad'):
                self.assertNotEqual(self.run_cmd([timer, 'arm', seconds], False).returncode, 0)
            self.assertFalse((self.base / 'scheduled').exists())
            self.env['FAIL_SCHEDULE'] = '1'
            result = self.run_cmd([timer, 'arm', '60'], False)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(json.loads(result.stdout)['armed'])
            (self.base / 'scheduled').unlink()

    def test_panel_commands_and_ipc(self):
        # Run the actual QML JavaScript functions with Quickshell mocked out.
        source = (REPO / 'Panel.qml').read_text()
        functions = []
        for name in ('sessionCommand', 'buildAllActions', 'menuActionString', 'shellQuote', 'scriptPath'):
            match = re.search(r'^  function ' + name + r'\(.*?^  }', source, re.M | re.S)
            self.assertIsNotNone(match)
            functions.append(match.group())
        ipc = re.findall(r'    function (?:logout|reboot|shutdown|rebootTimerArm|shutdownTimerArm|rebootTimerCancel|shutdownTimerCancel)\([^\n]+', source)
        ipc = [re.sub(r': (?:void|int)', '', f.strip()) for f in ipc]
        js = '''
const calls = [];
const Quickshell = {execDetached: cmd => calls.push(cmd)};
const root = {pluginDir: process.argv[1], btopCommand: () => [],
 armTimer: seconds => calls.push([root.timerKind, seconds]),
 cancelTimerById: id => calls.push([id])};
''' + '\n'.join(functions + ipc) + '''
Object.assign(root, {sessionCommand, scriptPath, shellQuote});
const rows = buildAllActions().filter(a => ['logout','reboot','shutdown'].includes(a.id));
logout(); reboot(); shutdown();
root.timerKind = 'shutdown'; rebootTimerArm(60); rebootTimerCancel();
root.timerKind = 'reboot'; shutdownTimerArm(90); shutdownTimerCancel();
console.log(JSON.stringify({rows: rows.map(a => a.command), menu: rows.map(menuActionString), calls}));
'''
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node.js is needed to exercise the QML JavaScript')
        result = json.loads(self.run_cmd([node, '-e', js, str(self.plugin)]).stdout)
        expected = [[str(self.plugin / 'bin/session-action'), a] for a in ('logout', 'reboot', 'shutdown')]
        self.assertEqual(result['rows'], expected)
        self.assertEqual(result['calls'][:3], expected)
        self.assertEqual(result['calls'][3:], [['reboot', 60], ['reboot-timer'], ['shutdown', 90], ['shutdown-timer']])
        self.omarchy('omarchy-system')
        for command in result['rows'] + result['calls'][:3]:
            self.run_cmd(command)
        for command in result['menu']:
            self.run_cmd(['/bin/bash', '-c', command])
        self.assertEqual(len(self.log.read_text().splitlines()), 9)

    def test_migrate_exact_legacy_menu_entries(self):
        module = runpy.run_path(str(REPO / 'add-to-omarchy-menu'))
        migrate = module['migrate_session_entries']
        menu = self.base / 'menu.jsonc'
        original = ('{\n'
                    '  "system.reboot": {"action": "omarchy-system-reboot"},\n'
                    '  "system.shutdown": {"action": "custom-shutdown"},\n'
                    '  "system.logout": {"action": "omarchy-system-logout"}\n'
                    '}\n')
        menu.write_text(original)
        migrate.__globals__.update(MENU_FILE=str(menu), default_ids=lambda: {'logout'})
        self.assertTrue(migrate())
        data = menu.read_text()
        self.assertNotIn('omarchy-system-reboot', data)
        self.assertIn('bin/session-action', data)
        self.assertIn('custom-shutdown', data)
        self.assertIn('omarchy-system-logout', data)
        self.assertFalse(migrate())

    def test_launch_menu_fallback(self):
        palette = runpy.run_path(str(REPO / 'add-to-omarchy-menu'))['_FALLBACK']
        self.omarchy('omarchy-system')
        for item in palette:
            if item['id'] in ('logout', 'reboot', 'shutdown'):
                argv = shlex.split(item['action'])
                self.assertEqual(argv, [str(REPO / 'bin/session-action'), item['id']])
                self.run_cmd(argv)
        self.assertEqual(self.log.read_text().splitlines(),
                         ['omarchy-system ' + a for a in ('logout', 'reboot', 'shutdown')])


if __name__ == '__main__':
    unittest.main()
