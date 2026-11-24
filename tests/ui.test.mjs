// The WebUI's editing logic in src/webroot/kcm.js: which layers the device can press, which rules
// an edit must cover, the effective-result rows, warnings, status parsing and the save diff.
// Effects are checked on maps produced by the real generator (patch.awk via busybox awk).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = process.env.ROOT || join(dirname(fileURLToPath(import.meta.url)), '..');
const KCM = createRequire(import.meta.url)(join(ROOT, 'src/webroot/kcm.js'));
const ORIGINAL_FILE = join(ROOT, 'tests/fixtures/key2-base.kcm');
const original = KCM.parseKcm(readFileSync(ORIGINAL_FILE, 'latin1'));
const KEY2 = KCM.availableModifiers(['SHIFT_LEFT', 'SHIFT_RIGHT', 'ALT_LEFT', 'SYM', 'CTRL_LEFT']);
const { META: M } = KCM;
const work = mkdtempSync(join(tmpdir(), 'ui-test-'));
process.on('exit', () => rmSync(work, { recursive: true, force: true }));

function generated(assignments) {
  writeFileSync(join(work, 'config'), ['# config', ...assignments].join('\n') + '\n');
  return KCM.parseKcm(execFileSync('busybox',
    ['awk', '-f', join(ROOT, 'src/patch.awk'), join(work, 'config'), ORIGINAL_FILE], { encoding: 'latin1' }));
}

test('the KEY2 key layout can press Shift (both sides), left Alt, SYM, left Ctrl and Shift lock', () => {
  for (const m of ['shift', 'lshift', 'rshift', 'alt', 'lalt', 'ctrl', 'lctrl', 'sym', 'capslock']) assert.ok(KEY2.has(m), m);
  for (const m of ['ralt', 'rctrl', 'meta', 'fn', 'numlock', 'scrolllock']) assert.ok(!KEY2.has(m), m);
  assert.deepEqual(KCM.unreachableParts('ralt+sym', KEY2), ['ralt']);
  assert.ok(!KCM.availableModifiers(['SYM']).has('capslock'));
});

test('press states: held keys carry side bits, tapped Shift/Alt/SYM only reach characters', () => {
  assert.deepEqual(KCM.pressStates('alt', KEY2),
    [{ how: 'held', meta: M.ALT | M.ALT_LEFT }, { how: 'tapped', meta: M.ALT }]);
  assert.deepEqual(KCM.pressStates('ctrl', KEY2), [{ how: 'held', meta: M.CTRL | M.CTRL_LEFT }]);
  assert.deepEqual(KCM.pressStates('sym', KEY2), [{ how: 'held', meta: M.SYM }, { how: 'tapped', meta: M.SYM }]);
  assert.deepEqual(KCM.pressStates('capslock', KEY2), [{ how: 'locked', meta: M.CAPS_LOCK }]);
  assert.deepEqual(KCM.pressStates('base', KEY2), [{ how: 'held', meta: 0 }]);
  const rightOnly = KCM.availableModifiers(['SHIFT_RIGHT']);
  assert.deepEqual(KCM.pressStates('shift', rightOnly)[0], { how: 'held', meta: M.SHIFT | M.SHIFT_RIGHT });
});

test('an Alt edit must also cover the existing left-Alt rule; others need nothing extra', () => {
  assert.deepEqual(KCM.companions('alt', KCM.ruleLayers(original, 'Q'), KEY2), ['lalt']);
  assert.deepEqual(KCM.companions('sym', KCM.ruleLayers(original, 'Q'), KEY2), []);
  assert.deepEqual(KCM.companions('shift+alt', KCM.ruleLayers(original, 'Q'), KEY2), []);
  assert.deepEqual(KCM.companions('alt', new Set(['alt', 'ralt']), KEY2), [], 'right Alt is not on the device');
});

test('writing Alt together with its companion gives the same character held and tapped', () => {
  const layers = ['alt', ...KCM.companions('alt', KCM.ruleLayers(original, 'Q'), KEY2)];
  const kcm = generated(layers.map((l) => l + ':Q=U_00E9'));
  for (const s of KCM.pressStates('alt', KEY2)) assert.equal(KCM.evaluate(kcm, 'Q', s.meta).character, 0xe9, s.how);
  const altOnly = generated(['alt:Q=U_00E9']);
  assert.equal(KCM.evaluate(altOnly, 'Q', M.ALT | M.ALT_LEFT).character, '1'.charCodeAt(0), 'held Alt hits lalt');
});

test('effective rows cover every combination of the device modifiers and flag changed ones', () => {
  const kcm = generated(['sym:H=R_DPAD_LEFT']);
  const rows = KCM.effectiveRows(kcm, original, 'H', KEY2);
  assert.equal(rows.length, 17, '2^4 combinations of shift/alt/ctrl/sym plus Shift lock');
  const changed = rows.filter((r) => r.changed).map((r) => r.layer);
  assert.deepEqual(changed, ['sym', 'shift+sym']);
  const sym = rows.find((r) => r.layer === 'sym');
  assert.equal(sym.states[0].result.key, 'DPAD_LEFT');
  assert.equal(sym.states[1].how, 'tapped');
  assert.equal(sym.states[1].result.character, 0, 'tapped SYM looks up the character of the replace rule');
  assert.equal(rows.find((r) => r.layer === 'alt+sym').states[0].result.rule.source, 'lalt');
});

test('warnings name unreachable modifiers, ordinary typing, common shortcuts and Alt+Space', () => {
  const w = (layer, key, value) => KCM.warnings({ layer, key, value, available: KEY2 }).join('\n');
  assert.match(w('ralt', 'Q', 'U_0041'), /押せない修飾（右Alt）/);
  assert.match(w('ralt', 'Q', 'KEEP'), /押せない修飾/);
  assert.match(w('base', 'Q', 'U_0041'), /通常の文字入力/);
  assert.match(w('ctrl', 'C', 'R_TAB'), /Ctrl\+C/);
  assert.doesNotMatch(w('shift+ctrl', 'C', 'R_TAB'), /Ctrl\+C/);
  assert.match(w('alt', 'SPACE', 'R_LANGUAGE_SWITCH'), /Alt\+Space/);
  assert.match(w('alt', 'Q', 'R_TAB'), /置き換えとフォールバックは、押したままの入力にだけ/);
  assert.equal(w('sym', 'H', 'R_DPAD_LEFT').includes('通常の文字入力'), false);
});

test('warnings report an edit hidden by a narrower rule, and not once the companion is written', () => {
  const hidden = KCM.warnings({ layer: 'alt', key: 'Q', value: 'U_00E9', available: KEY2,
    preview: generated(['alt:Q=U_00E9']) });
  assert.ok(hidden.some((m) => m.includes('押したままの入力は別のルール（lalt）')), hidden.join('\n'));
  const covered = KCM.warnings({ layer: 'alt', key: 'Q', value: 'U_00E9', available: KEY2, sameAs: ['lalt'],
    preview: generated(['alt:Q=U_00E9', 'lalt:Q=U_00E9']) });
  assert.ok(!covered.some((m) => m.includes('効きません')), covered.join('\n'));
});

test('status lines parse into diagnostics', () => {
  const st = KCM.parseStatus('kl_loaded=/vendor/usr/keylayout/stmpe.kl\nkcm_loaded=/system/usr/keychars/Generic.kcm\n' +
    'shadowed_by=/product/usr/keychars/stmpe.kcm\nconflict_module=other\napplied=no\nkl_applied=yes\nkl_editable=yes\n' +
    'kl_base=42:SHIFT_LEFT\nkl_base=110:CTRL_LEFT\nkl_live=110:ESCAPE\nflag=update\n');
  assert.deepEqual(st, { kcmLoaded: '/system/usr/keychars/Generic.kcm', klLoaded: '/vendor/usr/keylayout/stmpe.kl',
    shadowedBy: ['/product/usr/keychars/stmpe.kcm'], conflicts: ['other'], applied: false, klApplied: true,
    klEditable: true, flags: ['update'], klBase: { 42: 'SHIFT_LEFT', 110: 'CTRL_LEFT' }, klLive: { 110: 'ESCAPE' },
    tpSaved: 'rom', tpLive: 'rom', tpExcluded: '', tpForeign: [], tpConflicts: [], tpThresholds: [], tpDaemon: '', tpDaemonLog: '' });
  const tp = KCM.parseStatus('tp_saved=off\ntp_live=foreign\ntp_excluded=no\ntp_foreign=/system/etc/excluded-input-devices.xml\n' +
    'tp_conflict_module=other\n');
  assert.deepEqual([tp.tpSaved, tp.tpLive, tp.tpExcluded, tp.tpForeign, tp.tpConflicts],
    ['off', 'foreign', 'no', ['/system/etc/excluded-input-devices.xml'], ['other']]);
});

test('gestures: the 13 of touchgestured, their names, and their key values', () => {
  assert.equal(KCM.TOUCH_GESTURES.length, 13);
  assert.deepEqual(KCM.TOUCH_GESTURES.map((g) => g.id).slice(0, 5), ['swipe_up', 'swipe_down', 'swipe_left', 'swipe_right', 'flick_up']);
  assert.deepEqual(KCM.TOUCH_GESTURES.map((g) => g.id), ['swipe_up', 'swipe_down', 'swipe_left', 'swipe_right',
    'flick_up', 'flick_down', 'flick_left', 'flick_right', 'flick_upleft', 'flick_upright', 'flick_downleft', 'flick_downright', 'tap']);
  assert.throws(() => KCM.validate({ 'tp:2_pass': 'on', 'tp:2_tap': 'ENTER' }), /2本指/);
  assert.throws(() => KCM.validate({ 'tp:2_pass': 'on', 'tp:sym_2_tap': 'ENTER' }), /2本指/);
  assert.ok(KCM.validate({ 'tp:shift_1_swipe_left': 'MOVE_HOME+shift', 'tp:ctrl_3_flick_downright': 'ENTER', 'tp:1_swipe_left': 'DPAD_LEFT' }));
  for (const bad of ['tp:meta_1_tap', 'tp:shift_1_pass', 'tp:shift_shift_1_tap', 'tp:_1_tap']) {
    assert.throws(() => KCM.validate({ [bad]: bad.endsWith('pass') ? 'on' : 'ENTER' }), bad);
  }
  assert.equal(KCM.gestureName('tp:shift_2_flick_upleft'), 'Shift＋2本指で払う↖');
  assert.equal(KCM.gestureId('sym', '3', 'tap'), 'tp:sym_3_tap');
  assert.equal(KCM.gestureId('', '1', 'swipe_up'), 'tp:1_swipe_up');
  assert.ok(KCM.validate({ 'tp:2_pass': 'on', 'tp:1_tap': 'ENTER' }));
  assert.equal(KCM.gestureName('tp:2_flick_upleft'), '2本指で払う↖');
  assert.equal(KCM.gestureName('tp:1_tap'), '1本指でタップ');
  for (const g of KCM.TOUCH_GESTURES) assert.ok(KCM.validate({ ['tp:3_' + g.id]: 'ENTER' }), g.id);
  assert.deepEqual(KCM.parseTouchKey('DPAD_LEFT+shift+ctrl'), { code: 'DPAD_LEFT', mods: ['ctrl', 'shift'], once: false });
  assert.equal(KCM.formatTouchKey('DPAD_LEFT', ['meta', 'ctrl']), 'DPAD_LEFT+ctrl+meta');
  assert.equal(KCM.formatTouchKey('ENTER', []), 'ENTER');
  assert.equal(KCM.touchKeyText('DPAD_LEFT+ctrl+shift'), 'Ctrl+Shift+←');
  assert.deepEqual(KCM.parseTouchKey('PAGE_UP+once+ctrl'), { code: 'PAGE_UP', mods: ['ctrl'], once: true });
  assert.deepEqual(KCM.parseTouchKey('PAGE_UP'), { code: 'PAGE_UP', mods: [], once: false });
  assert.equal(KCM.formatTouchKey('PAGE_UP', ['shift'], true), 'PAGE_UP+shift+once');
  assert.equal(KCM.formatTouchKey('PAGE_UP', ['shift']), 'PAGE_UP+shift');
  assert.equal(KCM.touchKeyText('PAGE_UP+once'), 'PgUp（1回）');
  assert.ok(KCM.validate({ 'tp:1_swipe_up': 'PAGE_UP+once', 'tp:alt_2_swipe_left': 'MOVE_HOME+ctrl+once' }));
  for (const bad of [{ 'tp:1_tap': 'ENTER+once' }, { 'tp:1_flick_up': 'PAGE_UP+once' }, { 'tp:1_swipe_up': 'PAGE_UP+once+once' },
    { 'tp:1_swipe_up': 'PAGE_UP+once+ctrl' }]) {
    assert.throws(() => KCM.validate(bad), JSON.stringify(bad));
  }
});

test('thresholds are checked against the range touchgestured reports', () => {
  const mm = { name: 'step_mm', min: 0.5, max: 25, integer: false };
  const ms = { name: 'tap_ms', min: 0, max: 2000, integer: true };
  for (const ok of ['0.5', '3', '2.5', '25', '2.123456']) assert.ok(KCM.validThreshold(mm, ok), ok);
  for (const bad of ['0.4', '25.1', '', '2.', '.5', '-1', '1e2', 'x', '2.1234567', '000003']) assert.ok(!KCM.validThreshold(mm, bad), bad);
  assert.ok(KCM.validThreshold(ms, '0') && KCM.validThreshold(ms, '2000'));
  assert.ok(!KCM.validThreshold(ms, '10.5') && !KCM.validThreshold(ms, '2001'));
});

test('diagnostics warn when the gesture daemon is not running in gesture mode', () => {
  const text = (s) => KCM.diagnose(KCM.parseStatus(GOOD_STATUS + s)).map((d) => (d.warn ? '!' : '') + d.text);
  const live = 'tp_saved=gesture\ntp_live=gesture\ntp_excluded=yes\n';
  assert.ok(text(live + 'tp_daemon=stopped\ntp_daemon_log=touchgestured: no uinput\n')
    .includes('!ジェスチャーを読み取る常駐プログラムが動いていません。最後の記録：touchgestured: no uinput'));
  assert.ok(text(live + 'tp_daemon=running\n').every((t) => !t.startsWith('!')));
  assert.ok(text('tp_saved=gesture\ntp_live=off\ntp_daemon=stopped\n').every((t) => !t.includes('常駐プログラム')), 'pending reboot');
  const pending = text(live + 'tp_daemon=pending\n');
  assert.ok(pending.includes('割り当てたジェスチャーは、再起動後に使えます。') && pending.every((t) => !t.startsWith('!')), pending.join('\n'));
  const unneeded = text(live + 'tp_daemon=unneeded\n');
  assert.ok(unneeded.includes('ジェスチャーが割り当てられていないため、常駐プログラムは動かしていません。') &&
    unneeded.every((t) => !t.startsWith('!')), unneeded.join('\n'));
});

test('status lines give the thresholds from touchgestured and whether it runs', () => {
  const st = KCM.parseStatus('tp_threshold=step_mm:3:0.5:25:real\ntp_threshold=tap_ms:200:0:2000:int\ntp_threshold=bad:x:1:2:int\n' +
    'tp_threshold=old:1:0:2\n' +
    'tp_daemon=stopped\ntp_daemon_log=touchgestured: /dev/uinput: Permission denied\n');
  assert.deepEqual(st.tpThresholds, [{ name: 'step_mm', def: 3, min: 0.5, max: 25, integer: false },
    { name: 'tap_ms', def: 200, min: 0, max: 2000, integer: true }]);
  assert.equal(st.tpDaemon, 'stopped');
  assert.equal(st.tpDaemonLog, 'touchgestured: /dev/uinput: Permission denied');
});

test('touch surface settings: the modes, thresholds, gesture keys and passthrough', () => {
  const good = { 'tp:mode': 'gesture', 'tp:step_mm': '2.5', 'tp:tap_ms': '200', 'tp:1_swipe_left': 'DPAD_LEFT+shift',
    'tp:1_flick_upleft': 'MOVE_HOME+ctrl+alt', 'tp:3_tap': 'ENTER', 'tp:2_pass': 'on', 'sym:H': 'R_DPAD_LEFT' };
  assert.deepEqual(KCM.validate(good), Object.assign(Object.create(null), good));
  assert.deepEqual(KCM.validate({ 'tp:mode': 'off' }), Object.assign(Object.create(null), { 'tp:mode': 'off' }));
  for (const bad of [{ 'tp:mode': 'on' }, { 'tp:mode': 'rom' }, { 'tp:speed': 'off' }, { 'tp:mode': 'R_TAB' },
    { 'tp:step_mm': '2.' }, { 'tp:step_mm': 'fast' }, { 'tp:4_tap': 'ENTER' }, { 'tp:1_swipe_upleft': 'ENTER' },
    { 'tp:1_tap': 'enter' }, { 'tp:1_tap': 'ENTER+super' }, { 'tp:1_tap': 'ENTER+ctrl+ctrl' }, { 'tp:1_tap': 'ENTER+' },
    { 'tp:1_pass': 'yes' }, { 'tp:1_tap': 3 }]) {
    assert.throws(() => KCM.validate(bad), JSON.stringify(bad));
  }
});

test('diagnostics tell whether the touch surface is off, pending, or blocked', () => {
  const text = (s) => KCM.diagnose(KCM.parseStatus(GOOD_STATUS + s)).map((d) => (d.warn ? '!' : '') + d.text);
  assert.ok(text('tp_saved=off\ntp_live=off\ntp_excluded=yes\n').includes('キーボードのタッチ操作はオフです。'));
  const pending = text('tp_saved=off\ntp_live=rom\ntp_excluded=no\n');
  assert.ok(pending.includes('キーボードのタッチ操作は再起動後にオフになります。'));
  assert.ok(pending.includes('保存した設定は再起動後に反映されます。'), 'a pending touch change is not "in use"');
  const unused = text('tp_saved=off\ntp_live=off\ntp_excluded=no\n');
  assert.ok(unused.includes('!タッチ操作をオフにする設定は配置されていますが、Androidに使われていません。'), unused.join('\n'));
  assert.ok(unused.every((t) => !t.includes('タッチ操作はオフです') && !t.includes('再起動後にオフ')), 'neither off nor pending');
  assert.ok(text('tp_saved=rom\ntp_live=off\n').includes('キーボードのタッチ操作は再起動後にROMの標準に戻ります。'));
  const gesture = text('tp_saved=gesture\ntp_live=gesture\ntp_excluded=yes\n');
  assert.ok(gesture.includes('キーボードのタッチ操作は独自ジェスチャーです。'), gesture.join('\n'));
  assert.ok(gesture.includes('保存した設定は使用中です。') && gesture.every((t) => !t.startsWith('!')), gesture.join('\n'));
  assert.ok(text('tp_saved=gesture\ntp_live=off\ntp_excluded=yes\n').includes('キーボードのタッチ操作は再起動後に独自ジェスチャーになります。'));
  assert.ok(text('tp_saved=gesture\ntp_live=gesture\ntp_excluded=no\n')
    .includes('!タッチ操作を独自ジェスチャーにする設定は配置されていますが、Androidに使われていません。'));
  assert.ok(text('tp_saved=rom\ntp_live=gesture\n').includes('キーボードのタッチ操作は再起動後にROMの標準に戻ります。'));
  assert.ok(text('tp_saved=rom\ntp_live=rom\n').every((t) => !t.includes('タッチ')), 'the ROM default needs no line');
  const blocked = KCM.diagnose(KCM.parseStatus(GOOD_STATUS + 'tp_live=foreign\ntp_excluded=yes\n' +
    'tp_foreign=/system/etc/excluded-input-devices.xml\ntp_conflict_module=other\n'));
  const warned = blocked.filter((d) => d.warn).map((d) => d.text);
  assert.equal(warned.length, 3, warned.join('\n'));
  assert.match(warned[0], /\/system\/etc\/excluded-input-devices\.xmlがあるため/);
  assert.match(warned[1], /モジュールotherも/);
  assert.match(warned[2], /このモジュール以外の設定で/);
  assert.ok(blocked.findIndex((d) => !d.warn) > blocked.findLastIndex((d) => d.warn), 'problems come first');
});

test('save diff lists added, changed and removed assignments in id order', () => {
  assert.deepEqual(KCM.diffAssignments({ 'sym:H': 'R_DPAD_LEFT', 'sym:J': 'R_DPAD_DOWN' },
    { 'sym:H': 'R_TAB', 'alt:Q': 'U_00E9', 'sym:J': 'R_DPAD_DOWN' }), [
    { id: 'alt:Q', from: undefined, to: 'U_00E9' },
    { id: 'sym:H', from: 'R_DPAD_LEFT', to: 'R_TAB' },
  ]);
  assert.deepEqual(KCM.diffAssignments({ 'sym:H': 'R_TAB' }, {}), [{ id: 'sym:H', from: 'R_TAB', to: undefined }]);
});

const GOOD_STATUS = 'kl_loaded=/vendor/usr/keylayout/stmpe.kl\nkcm_loaded=/vendor/usr/keychars/stmpe.kcm\napplied=yes\n' +
  'kl_applied=yes\nkl_editable=yes\nkl_live=42:SHIFT_LEFT\nkl_live=56:ALT_LEFT\nkl_live=100:SYM\nkl_live=110:CTRL_LEFT\n';

test('diagnostics flag fallback files, shadowing, conflicts, missing originals and pending flags first', () => {
  const bad = KCM.diagnose(KCM.parseStatus('kl_loaded=/system/usr/keylayout/Generic.kl\nkcm_loaded=/system/usr/keychars/Generic.kcm\n' +
    'shadowed_by=/odm/usr/keychars/stmpe.kcm\nconflict_module=other\napplied=no\nkl_editable=no\nflag=update\n'));
  const warned = bad.filter((d) => d.warn).map((d) => d.text);
  [/Generic\.klを使っています/, /Generic\.kcmを使っています/, /\/odm\/usr\/keychars\/stmpe\.kcmが優先/, /モジュールotherも/,
    /入れ直して/, /更新が再起動待ち/].forEach((re, i) => assert.match(warned[i] || '', re));
  assert.equal(warned.length, 6);
  assert.ok(bad.findIndex((d) => !d.warn) > bad.findLastIndex((d) => d.warn));
  const good = KCM.diagnose(KCM.parseStatus(GOOD_STATUS));
  assert.ok(good.every((d) => !d.warn), JSON.stringify(good));
  assert.ok(good.some((d) => d.text.includes('使用中')));
  assert.ok(good.some((d) => d.text.includes('Speedは左Ctrl')));
  assert.ok(KCM.diagnose(KCM.parseStatus('applied=no\n'))[0].warn, 'unknown loaded files are a warning');
});

test('the palette offers every assignable key code exactly once', () => {
  const codes = KCM.PALETTE.flatMap((c) => c.codes);
  assert.equal(new Set(codes).size, codes.length);
  assert.deepEqual([...codes].sort(), Object.keys(KCM.ACTIONS).sort());
});

test('key-cap legends show replacements by short name, characters, no-character and undefined', () => {
  const kcm = generated(['sym:H=R_DPAD_LEFT', 'sym:A=NONE', 'sym:W=R_TAB']);
  const at = (key, meta) => KCM.legend(KCM.evaluate(kcm, key, meta));
  assert.deepEqual(at('H', M.SYM), { text: '←', kind: 'replace' });
  assert.deepEqual(at('W', M.SYM), { text: 'Tab', kind: 'replace' });
  assert.deepEqual(at('A', M.SYM), { text: '—', kind: 'none' });
  assert.deepEqual(at('Q', M.SYM), { text: '^', kind: 'char' });
  assert.deepEqual(at('SPACE', 0), { text: '␣', kind: 'char' });
  assert.deepEqual(at('ENTER', 0), { text: '⏎', kind: 'char' }, 'a newline character shows as a symbol');
  assert.deepEqual(at('DEL', 0), { text: '', kind: 'undefined' });
  assert.deepEqual(at('Q', M.CTRL | M.CTRL_LEFT), { text: '', kind: 'undefined' });
});

test('key presses map to Android key code labels and to editable KEY2 keys', () => {
  const cases = [[{ code: 'ArrowLeft', key: 'ArrowLeft' }, 'DPAD_LEFT'], [{ code: 'KeyQ', key: 'q' }, 'Q'],
    [{ code: 'Digit7', key: '7' }, '7'], [{ code: 'F11', key: 'F11' }, 'F11'], [{ code: 'Backspace', key: 'Backspace' }, 'DEL'],
    [{ code: 'Delete', key: 'Delete' }, 'FORWARD_DEL'], [{ code: 'Quote', key: "'" }, 'APOSTROPHE'],
    [{ code: '', key: 'Home' }, 'MOVE_HOME'], [{ code: '', key: 'x' }, 'X'], [{ code: 'ShiftLeft', key: 'Shift' }, null],
    [{ code: 'F13', key: 'F13' }, null]];
  for (const [e, want] of cases) assert.equal(KCM.keyCodeOf(e), want, JSON.stringify(e));
  for (const [e] of cases) {
    const code = KCM.keyCodeOf(e);
    if (code) assert.ok(code in KCM.ACTIONS, 'assignable: ' + code);
  }
  assert.equal(KCM.editableKeyOf({ code: 'KeyH', key: 'h' }), 'H');
  assert.equal(KCM.editableKeyOf({ code: 'Digit4', key: '$' }), '4');
  assert.equal(KCM.editableKeyOf({ code: '', key: '$' }), '4');
  assert.equal(KCM.editableKeyOf({ code: 'Space', key: ' ' }), 'SPACE');
  assert.equal(KCM.editableKeyOf({ code: 'Digit5', key: '5' }), null, 'KEY2 has no 5 key');
  assert.equal(KCM.editableKeyOf({ code: 'Tab', key: 'Tab' }), null);
});

test('modifier key roles: physical keys, allowed targets and assignment validation', () => {
  assert.deepEqual(Object.keys(KCM.PHYSICAL), ['42', '56', '100', '110']);
  assert.deepEqual(KCM.LAYOUT.flat().filter((k) => k.scan).map((k) => k.scan), [56, 42, 100, 110]);
  const width = (row) => row.reduce((w, k) => w + (k === 'SPACE' ? 4 : 1), 0);
  assert.deepEqual(KCM.LAYOUT.map(width), [10, 10, 10, 10], 'every row is ten key widths');
  assert.deepEqual(KCM.LAYOUT.flat().filter((k) => typeof k === 'string').sort(), [...KCM.KEYS].sort());
  assert.ok(KCM.validRole('kl:110', 'ESCAPE') && KCM.validRole('kl:100', 'CTRL_LEFT') && KCM.validRole('kl:42', 'CAPS_LOCK'));
  assert.ok(!KCM.validRole('kl:30', 'CTRL_LEFT') && !KCM.validRole('kl:110', 'POWER') && !KCM.validRole('kl:110', 'R_TAB'));
  assert.deepEqual(Object.keys(KCM.validate({ 'kl:110': 'ESCAPE', 'sym:H': 'R_DPAD_LEFT' })).sort(), ['kl:110', 'sym:H']);
  assert.throws(() => KCM.validate({ 'kl:54': 'SYM' }));
});

test('modifier key role changes are counted and reset with the base layer', () => {
  assert.equal(KCM.layerOf('kl:110'), 'base');
  assert.equal(KCM.layerOf('base:Q'), 'base');
  assert.equal(KCM.layerOf('sym:H'), 'sym');
  assert.equal(KCM.layerOf('shift+alt:Q'), 'shift+alt');
});

test('modifier key roles: the WebUI allows exactly the targets klpatch.awk accepts', () => {
  const kl = readFileSync(join(ROOT, 'tests/fixtures/key2-base.kl'), 'ascii');
  writeFileSync(join(work, 'base.kl'), kl);
  const accepted = readFileSync(join(ROOT, 'src/keycodes.txt'), 'ascii').trim().split('\n').filter((code) => {
    writeFileSync(join(work, 'kl.cfg'), '# config\nkl:110=' + code + '\n');
    try {
      execFileSync('busybox', ['awk', '-f', join(ROOT, 'src/klpatch.awk'), join(work, 'kl.cfg'), join(work, 'base.kl')], { stdio: 'ignore' });
      return true;
    } catch {
      return false;
    }
  });
  const webui = readFileSync(join(ROOT, 'src/keycodes.txt'), 'ascii').trim().split('\n').filter((c) => KCM.validRole('kl:110', c));
  assert.deepEqual(webui, accepted);
});

test('modifier key roles decide which layers can be pressed, and losing one is warned', () => {
  const base = { 42: 'SHIFT_LEFT', 56: 'ALT_LEFT', 100: 'SYM', 110: 'CTRL_LEFT' };
  const now = KCM.availableFromRoles(KCM.rolesOf(base, {}));
  for (const m of ['shift', 'lshift', 'alt', 'sym', 'ctrl', 'capslock']) assert.ok(now.has(m), m);
  assert.ok(!now.has('rshift'), 'the KEY2 has no right Shift key even though stmpe.kl maps scan code 54');
  const swapped = KCM.rolesOf(base, { 'kl:100': 'CTRL_LEFT', 'kl:110': 'SYM' });
  assert.deepEqual(swapped, { 42: 'SHIFT_LEFT', 56: 'ALT_LEFT', 100: 'CTRL_LEFT', 110: 'SYM' });
  const w = KCM.roleWarnings({ scan: '110', code: 'ESCAPE', base, map: { 'ctrl:C': 'R_TAB', 'sym:H': 'R_DPAD_LEFT' } });
  assert.match(w.join('\n'), /Ctrlを押せるキーがなくなります/);
  assert.match(w.join('\n'), /押せなくなるレイヤーに1件の割り当てがあります（ctrl:C）/);
  const fine = KCM.roleWarnings({ scan: '110', code: 'META_LEFT', base: { ...base, 110: 'CTRL_LEFT' }, map: {} });
  assert.match(fine.join('\n'), /Ctrlを押せるキーがなくなります/);
  assert.equal(KCM.roleWarnings({ scan: '42', code: 'SHIFT_RIGHT', base, map: {} }).length, 1, 'only the general notice');
  const sym = KCM.roleWarnings({ scan: '100', code: 'CTRL_RIGHT', base, map: { 'tp:sym_1_tap': 'ENTER', 'tp:shift_1_tap': 'TAB' } });
  assert.match(sym.join('\n'), /押せなくなるレイヤーに1件の割り当てがあります（SYM＋1本指でタップ）/, sym.join('\n'));
});
