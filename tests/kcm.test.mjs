// src/webroot/kcm.js: the WebUI's validation must agree with the generator (patch.awk), and its
// key evaluation must agree with the AOSP implementation (kcmtool, built from Android 16 source).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.env.ROOT || join(dirname(fileURLToPath(import.meta.url)), '..');
const KCMTOOL = process.env.KCMTOOL || join(ROOT, 'tools/kcm-host/kcmtool');
const AOSP_KEYBOARDS = process.env.AOSP_KEYBOARDS ||
  join(ROOT, 'tools/kcm-host/aosp/android-16.0.0_r1/keyboards');
const FIXTURES = join(ROOT, 'tests/fixtures');
const KCM = createRequire(import.meta.url)(join(ROOT, 'src/webroot/kcm.js'));
const KEYCODES = readFileSync(join(ROOT, 'src/keycodes.txt'), 'ascii').trim().split('\n');
const work = mkdtempSync(join(tmpdir(), 'kcm-test-'));
process.on('exit', () => rmSync(work, { recursive: true, force: true }));

/** Runs patch.awk (busybox awk, as on the device) on ORIGINAL with ASSIGNMENTS; null if it refuses. */
function generate(assignments, original = join(FIXTURES, 'key2-base.kcm')) {
  const config = join(work, 'config');
  writeFileSync(config, ['# config', ...assignments].join('\n') + '\n');
  try {
    return execFileSync('busybox', ['awk', '-f', join(ROOT, 'src/patch.awk'), config, original],
      { encoding: 'latin1', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

/** The WebUI's verdict on one saved assignment string "layer:KEY=VALUE". */
function webuiAccepts(assignment) {
  const m = assignment.match(/^([^:=]*):([^:=]*)=([^:=]*)$/);
  return !!m && KCM.validId(m[1] + ':' + m[2]) && KCM.validValue(m[3]);
}

test('WebUI and generator agree on the shared assignment vectors', () => {
  const lines = readFileSync(join(ROOT, 'tests/vectors/assignments.txt'), 'utf8')
    .split('\n').filter((l) => l && !l.startsWith('#'));
  assert.ok(lines.length > 20);
  for (const line of lines) {
    const [verdict, assignment] = line.split('|');
    assert.equal(webuiAccepts(assignment) ? 'accept' : 'reject', verdict, assignment);
  }
});

test('WebUI offers exactly the replacement key codes the generator accepts', () => {
  const generatorAccepts = KEYCODES.filter((code) => generate(['sym:A=R_' + code]) !== null);
  assert.deepEqual(Object.keys(KCM.ACTIONS).sort(), generatorAccepts.sort());
});

test('WebUI offers exactly the keys the generator accepts', () => {
  const generatorAccepts = KEYCODES.filter((code) => generate(['sym:' + code + '=NONE']) !== null);
  assert.deepEqual([...KCM.KEYS].sort(), generatorAccepts.sort());
});

test('canonical orders modifiers and rejects general+side mixes', () => {
  assert.equal(KCM.canonical('sym+shift'), 'shift+sym');
  assert.equal(KCM.canonical('lalt+lshift'), 'lshift+lalt');
  assert.equal(KCM.canonical('base'), 'base');
  assert.equal(KCM.canonical('alt+lalt'), '');
  assert.equal(KCM.canonical('sym+sym'), '');
  assert.equal(KCM.canonical(''), '');
});

// Modifier states compared with kcmtool: held keys (side + general bit), tapped/locked keys of
// the framework text path (general bit only), and the flags.
function metaStates() {
  const { META: M } = KCM;
  const sided = (g, l, r) => [0, g, g | l, g | r, g | l | r];
  let states = [0];
  for (const options of [sided(M.SHIFT, M.SHIFT_LEFT, M.SHIFT_RIGHT),
    sided(M.ALT, M.ALT_LEFT, M.ALT_RIGHT), [0, M.CTRL, M.CTRL | M.CTRL_LEFT, M.CTRL | M.CTRL_RIGHT],
    [0, M.META | M.META_LEFT], [0, M.SYM], [0, M.FUNCTION], [0, M.CAPS_LOCK]]) {
    states = states.flatMap((s) => options.map((o) => s | o));
  }
  return states;
}

function describe(r) {
  const hex = (n, w) => n.toString(16).padStart(w, '0');
  const fb = r.fallback ? r.fallback.key + '/0x' + hex(r.fallback.meta, 1) : '-/0x0';
  return `key=${r.key} meta=0x${hex(r.meta, 1)} char=0x${hex(r.character, 4)} fallback=${fb}`;
}

const sample = generate(['sym:H=R_DPAD_LEFT', 'shift+sym:H=R_DPAD_LEFT', 'sym:Z=F_F6', 'sym:A=NONE',
  'lshift+lalt:4=U_20AC', 'shift+ctrl:A=R_MOVE_HOME', 'lalt:SPACE=R_LANGUAGE_SWITCH',
  'sym:DEL=R_FORWARD_DEL', 'alt:Q=U_00E9', 'lctrl:W=F_TAB', 'capslock:E=R_ESCAPE',
  // Side-specific replacements: the general bit must come back for the other side (normalizeMetaState).
  'lshift:R=R_TAB', 'lctrl:T=R_MOVE_HOME']);
const maps = {
  'key2-base.kcm': join(FIXTURES, 'key2-base.kcm'),
  'key2-v03-live.kcm': join(FIXTURES, 'key2-v03-live.kcm'),
  'synthetic-key2.kcm': join(FIXTURES, 'synthetic-key2.kcm'),
  'Generic.kcm': join(AOSP_KEYBOARDS, 'Generic.kcm'),
  'generated sample': join(work, 'sample.kcm'),
};
writeFileSync(maps['generated sample'], sample, 'latin1');

for (const [name, file] of Object.entries(maps)) {
  test(`evaluator matches AOSP for every key and modifier state of ${name}`, () => {
    const kcm = KCM.parseKcm(readFileSync(file, 'latin1'));
    const keys = [...new Set([...Object.keys(kcm.keys), 'DEL', 'TAB'])];
    const states = metaStates();
    const queries = keys.flatMap((k) => states.map((m) => `${k} 0x${m.toString(16)}`));
    const expected = execFileSync(KCMTOOL, ['eval-many', file],
      { input: queries.join('\n') + '\n', encoding: 'ascii', maxBuffer: 1 << 28 }).trim().split('\n');
    assert.equal(expected.length, queries.length);
    const mismatches = [];
    queries.forEach((q, i) => {
      const [key, meta] = q.split(' ');
      const got = `${q} ${describe(KCM.evaluate(kcm, key, parseInt(meta, 16)))}`;
      if (got !== expected[i] && mismatches.length < 5) mismatches.push(`AOSP ${expected[i]}\nJS   ${got}`);
    });
    assert.deepEqual(mismatches, []);
  });
}

test('evaluator names the deciding rule', () => {
  const kcm = KCM.parseKcm(readFileSync(maps['generated sample'], 'latin1'));
  assert.equal(KCM.evaluate(kcm, 'SPACE', KCM.META.ALT | KCM.META.ALT_LEFT).rule.source, 'lalt');
  assert.equal(KCM.evaluate(kcm, 'SPACE', KCM.META.ALT).rule.source, 'alt');
  assert.equal(KCM.evaluate(kcm, 'H', KCM.META.SHIFT | KCM.META.SHIFT_LEFT | KCM.META.SYM).rule.source, 'shift+sym');
  assert.equal(KCM.evaluate(kcm, 'TAB', 0).rule, null);
});
