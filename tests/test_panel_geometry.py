"""Exercise the actual QML geometry bindings in JS, without a live desktop."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import unittest

PANEL = Path(__file__).resolve().parents[1] / 'CenterableKeyboardPanel.qml'


class PanelGeometry(unittest.TestCase):
    def test_placement_matrix(self):
        source = PANEL.read_text()
        # Evaluate production expressions/functions, rather than a Python copy.
        def expression(name):
            match = re.search(r'  readonly property \w+ ' + name + r': (.*?)(?=\n\n|\n  (?:readonly property|function))', source, re.S)
            self.assertIsNotNone(match, name)
            return match[1].strip()

        names = ['barThickness', 'availableCardWidth', 'availableCardHeight', 'cardOrigin']
        expressions = {name: expression(name) for name in names}
        clamp = re.search(r'  function clampOrigin\(.*?\n  }', source, re.S)[0]
        js = '''
const assert = require('node:assert/strict');
const Qt = {point: (x, y) => ({x, y})};
let margin, screenW, screenH, barPos, bar, screen, gap, centerOnScreen,
    centerOnBar, contentWidth, contentHeight, anchorScreenPos, anchorW, anchorH;
''' + clamp + '\nconst expr = ' + json.dumps(expressions) + ''';
let barThickness;
let cases = 0;
for (const [w, h] of [[1920,1080],[1280,720],[800,600],[640,360],[320,200],[100,80],
                       [1536,864],[1280,800],[1080,1920]]) {
 for (barPos of ['top','bottom','left','right']) {
  for (centerOnScreen of [false,true]) for (centerOnBar of [false,true]) {
   for (const modern of [false,true]) for (const styleScale of [1,1.5,2]) {
    screenW=w; screenH=h; screen={name:'scaled-output'};
    margin=8*styleScale; gap=8*styleScale;
    bar={barSize:30*styleScale};
    if (modern) bar.barSizeFor = name => {assert.equal(name,screen.name); return 42*styleScale;};
    barThickness=eval(expr.barThickness);
    assert.equal(barThickness,(modern?42:30)*styleScale);
    contentWidth=Math.min(300*styleScale,eval(expr.availableCardWidth));
    contentHeight=Math.min(560*styleScale,eval(expr.availableCardHeight));
    for (const edge of [0,0.5,1]) {
     anchorScreenPos={x:w*edge,y:h*edge}; anchorW=24; anchorH=24;
     const p=eval('(()=>'+expr.cardOrigin+')()');
     assert(p.x>=0 && p.y>=0, JSON.stringify(p));
     assert(p.x+contentWidth<=w+0.5 && p.y+contentHeight<=h+0.5);
     if (w===1920 && h===1080 && !centerOnScreen) {
      assert(contentHeight>120, 'full-screen backing window must not collapse the card');
      if (barPos==='top') assert.equal(p.y,barThickness+gap);
      if (barPos==='bottom') assert.equal(p.y,h-barThickness-gap-contentHeight);
     }
     cases++;
    }
   }
  }
 }
}
console.log(cases);
'''
        node = shutil.which('node')
        if not node:
            self.skipTest('Node.js is required for QML JavaScript geometry checks')
        result = subprocess.run([node, '-e', js], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(int(result.stdout), 2592)
