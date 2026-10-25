"""Test the production QML uptime formatter and persisted preferences."""
from pathlib import Path
import re
import shutil
import subprocess
import unittest


class Uptime(unittest.TestCase):
    def test_formats_and_preferences(self):
        source = (Path(__file__).resolve().parents[1] / 'Panel.qml').read_text()
        functions = []
        for name in ('validUptimeFormat', 'formatUptime', 'setUptimeFormat', 'loadSettings', 'saveSettings', 'caption'):
            match = re.search(r'^  function ' + name + r'\(.*?^  }', source, re.M | re.S)
            self.assertIsNotNone(match)
            functions.append(match.group())
        js = '''
const assert = require('node:assert/strict');
let saved;
const settingsFile = {setText: text => saved = text};
const root = {uptimeFormats:['compact','clock','hours'],
 normalizeOrder: order => order || [], rebuild(){}, syncMenuEntries(){},
 view:'actions', armedId:'', uptimeSeconds:183845,
 timerNoun:()=> 'shutdown', formatRemaining:()=> '01:00'};
''' + '\n'.join(functions) + '''
Object.assign(root,{validUptimeFormat,formatUptime,saveSettings});
for (const [seconds, compact, clock, hours] of [
 [0,'0h 0m','00:00:00','0h 00m 00s'],
 [59,'0h 0m','00:00:59','0h 00m 59s'],
 [3600,'1h 0m','01:00:00','1h 00m 00s'],
 [86400,'1d 0h 0m','1d 00:00:00','24h 00m 00s'],
 [183845.9,'2d 3h 4m','2d 03:04:05','51h 04m 05s']]) {
 assert.equal(formatUptime(seconds,'compact'),compact);
 assert.equal(formatUptime(seconds,'clock'),clock);
 assert.equal(formatUptime(seconds,'hours'),hours);
}
assert.equal(formatUptime(-1,'clock'),'00:00:00');
loadSettings('{"order":["lock"],"hidden":{"reboot":true}}');
assert.equal(root.uptimeFormat,'compact');
setUptimeFormat('clock');
assert.equal(JSON.parse(saved).uptimeFormat,'clock');
assert.deepEqual(JSON.parse(saved).order,['lock']);
assert.deepEqual(JSON.parse(saved).hidden,{reboot:true});
loadSettings(saved);
assert.equal(caption(),'Uptime 2d 03:04:05');
root.armedId='shutdown'; assert.equal(caption(),'CONFIRM TO CONTINUE');
root.view='settings'; assert.equal(caption(),'CUSTOMIZE BUTTONS');
root.view='timer'; root.timerArmed=true; assert.equal(caption(),'SHUTDOWN IN 01:00');
loadSettings('{"uptimeFormat":"invalid"}'); assert.equal(root.uptimeFormat,'compact');
loadSettings('broken json'); assert.equal(root.uptimeFormat,'compact');
'''
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js required')
        result = subprocess.run([node, '-e', js], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
