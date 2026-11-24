'use strict';
/* DOM side of the WebUI. Validation, KCM reading and evaluation live in kcm.js (global KCM). */
const $ = (id) => document.getElementById(id);
const REMAP = '/data/adb/modules/key2_remap_gui/remap.sh';
const { ACTIONS, PHYSICAL, canonical, validValue, validate, parseKcm } = KCM;
const NAMES = { SPACE: 'Space', DEL: '⌫', ENTER: '⏎', 4: '$', 0: '🎤0' };
const GROUPS = [['shift', 'Shift'], ['alt', 'Alt'], ['ctrl', 'Ctrl'], ['meta', 'Meta']];
const FLAGS = ['sym', 'fn', 'capslock', 'numlock', 'scrolllock'];
const HOW = { held: '押したまま', tapped: '一度押し', locked: 'Shiftロック' };
const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
let map = Object.create(null);
let saved = Object.create(null);
let originalKcm = null;
let previewKcm = null;
let previewError = '';
// The edits previewKcm was generated from; warnings use the preview only while it is current.
let previewOf = '';
let previewSeq = 0;
// Until remap.sh status reports the key layout, treat every modifier as pressable.
let available = KCM.availableModifiers(['SHIFT_LEFT', 'SHIFT_RIGHT', 'ALT_LEFT', 'ALT_RIGHT', 'CTRL_LEFT',
  'CTRL_RIGHT', 'META_LEFT', 'META_RIGHT', 'SYM', 'FUNCTION', 'CAPS_LOCK', 'NUM_LOCK', 'SCROLL_LOCK']);
// Physical modifier keys' original (base.kl) and live roles, scan code -> key code label.
let klBase = {};
let klLive = {};
let klEditable = false;
// Other excluded device lists that keep this module from turning the touch surface off.
let touchBlockers = [];
let touchThresholds = [];
let touchLayer = '';
let touchFingers = '1';
let touchGesture = null;
let touchCategory = 'cursor';
let current = 'base';
// Character key being edited; null with selectedMod also null until a key is chosen.
let selected = null;
// Scan code of the physical modifier key being edited, or null while a character key is selected.
let selectedMod = null;
let category = 'cursor';
// "target": the next key press becomes the assigned output; "source": it selects the key to edit.
let capture = '';
let seq = 0;

function status(s) { $('status').textContent = s; }

/**
 * Runs remap.sh with ARGS through WebUI X's ksu.exec(command, callbackName) and resolves with its
 * stdout when the exit code is 0. WebUI X calls window[callbackName](exitCode, stdout, stderr).
 */
function bridge(args) {
  return new Promise((resolve, reject) => {
    if (!window.ksu || typeof window.ksu.exec !== 'function') {
      reject(new Error('WebUI Xで開き、rootとSHELL権限を許可してください。'));
      return;
    }
    // The same alphabet remap.sh accepts ("." only matters in touch thresholds); none is special to sh.
    if (!args.every((a) => /^[A-Za-z0-9_+:=.]+$/.test(a))) { reject(new Error('実行できない引数です。')); return; }
    const cb = 'key2remapCb' + (++seq);
    let timer;
    const done = () => { clearTimeout(timer); delete window[cb]; };
    const giveUpAfter = (ms, message) => {
      clearTimeout(timer);
      timer = setTimeout(() => { done(); reject(new Error(message)); }, ms);
    };
    window[cb] = (code, out, err) => {
      done();
      if (Number(code) === 0) resolve(String(out ?? ''));
      else reject(new Error(String(err || out || '実行に失敗しました（終了コード ' + code + '）')));
    };
    giveUpAfter(120000, '実行結果を確認できません。画面を開き直して確認してください。');
    let returned;
    try {
      returned = window.ksu.exec('sh ' + REMAP + ' ' + args.join(' '), cb);
    } catch (e) {
      done();
      reject(e);
      return;
    }
    // Without the SHELL permission WebUI X shows its permission dialog and returns null instead
    // of running the command. The normal return value of this callback form is not documented,
    // so null only shortens the wait rather than failing at once.
    if (returned === null) {
      giveUpAfter(10000, 'シェル権限が許可されていない可能性があります。WebUI Xでこのモジュールの権限を確認してください。');
    }
  });
}

/** In-page OK/cancel dialog; window.confirm is not reliable in WebUI X. Resolves true on OK. */
function ask(message, ok = 'OK', cancel = 'キャンセル') {
  const dialog = $('confirm');
  $('confirmText').textContent = message;
  dialog.querySelector('button[value=ok]').textContent = ok;
  dialog.querySelector('button[value=cancel]').textContent = cancel;
  dialog.returnValue = '';
  dialog.showModal();
  return new Promise((resolve) => { dialog.onclose = () => resolve(dialog.returnValue === 'ok'); });
}

function el(tag, props = {}, ...children) {
  const e = document.createElement(tag);
  Object.assign(e, props);
  e.append(...children);
  return e;
}

function button(text, fn, className = '') {
  return el('button', { type: 'button', textContent: text, onclick: fn, className });
}

function keyName(k) { return NAMES[k] || k; }

function layerName(l) {
  if (l === 'base') return '通常';
  if (l === 'capslock' && !available.has('CAPS_LOCK')) return 'Shiftロック';
  return l.split('+').map(KCM.modifierLabel).join('+');
}

function charText(c) {
  if (!c) return '文字なし';
  if (c === 0x20) return '空白';
  const s = String.fromCharCode(c);
  return /\s/.test(s) ? 'U+' + c.toString(16).toUpperCase().padStart(4, '0') : "'" + s + "'";
}

/** What one press state produces: key and fallback when held, the character only otherwise. */
function resultText(how, r) {
  if (how !== 'held') return charText(r.character);
  if (!r.rule) return '定義なし';
  const parts = [r.rule.replace ? (ACTIONS[r.key] || r.key) + 'キー' : charText(r.character)];
  if (r.fallback) parts.push('フォールバック：' + (ACTIONS[r.fallback.key] || r.fallback.key));
  return parts.join(' / ');
}

/** Text of an assignment value; IDs of modifier key roles ("kl:SCAN") hold a key code label. */
function valueText(v, id = '') {
  if (id.startsWith('kl:')) return v ? '→ ' + KCM.roleName(v) : '元のまま（' + KCM.roleName(klBase[id.slice(3)] || '') + '）';
  if (!v) return '元のまま';
  if (v === 'NONE') return '文字なし';
  if (v.startsWith('U_')) return charText(parseInt(v.slice(2), 16));
  return (v.startsWith('F_') ? 'FB: ' : '→ ') + (ACTIONS[v.slice(2)] || v.slice(2));
}

// Key-cap names of modifier key roles.
const ROLE_CAPS = { SHIFT_LEFT: '⇧', SHIFT_RIGHT: '⇧R', ALT_LEFT: 'Alt', ALT_RIGHT: 'AltR', CTRL_LEFT: 'Ctrl',
  CTRL_RIGHT: 'CtrlR', META_LEFT: 'Meta', META_RIGHT: 'MetaR', SYM: 'Sym', FUNCTION: 'Fn', CAPS_LOCK: 'Caps' };
// Modifier group a modifier key code belongs to, for lighting the keys of the current layer.
const ROLE_GROUP = { SHIFT_LEFT: ['shift', 'lshift'], SHIFT_RIGHT: ['shift', 'rshift'], ALT_LEFT: ['alt', 'lalt'],
  ALT_RIGHT: ['alt', 'ralt'], CTRL_LEFT: ['ctrl', 'lctrl'], CTRL_RIGHT: ['ctrl', 'rctrl'], META_LEFT: ['meta', 'lmeta'],
  META_RIGHT: ['meta', 'rmeta'], SYM: ['sym'], FUNCTION: ['fn'], CAPS_LOCK: ['capslock'] };
// KeyboardEvent.code of modifier keys -> key code label (for picking keys by pressing them).
const MODIFIER_CODES = { ShiftLeft: 'SHIFT_LEFT', ShiftRight: 'SHIFT_RIGHT', AltLeft: 'ALT_LEFT', AltRight: 'ALT_RIGHT',
  ControlLeft: 'CTRL_LEFT', ControlRight: 'CTRL_RIGHT', MetaLeft: 'META_LEFT', MetaRight: 'META_RIGHT', CapsLock: 'CAPS_LOCK' };

function roles() { return KCM.rolesOf(klBase, map); }

function roleCap(code) { return ROLE_CAPS[code] || KCM.shortName(code); }

function modName(scan) { return PHYSICAL[scan] + 'キー'; }

function assignmentArgs() {
  return Object.entries(map).sort().map(([k, v]) => k + '=' + v);
}

/** The map that shows the edits: the latest preview, or the original until one arrives. */
function shownKcm() { return previewKcm || originalKcm; }

/** Layers that get the same value as LAYER on KEY (see KCM.companions). */
function sameAs(l, key = selected) {
  return originalKcm ? KCM.companions(l, KCM.ruleLayers(shownKcm(), key), available) : [];
}

// --- Layer selection: tabs for the device's single modifiers, the detailed selectors in a fold.

function tabLayers() {
  const tabs = ['base', ...['shift', 'alt', 'sym', 'ctrl', 'meta', 'fn'].filter((g) => available.has(g))];
  if (available.has('capslock')) tabs.push('capslock');
  return tabs;
}

function layerFromSelectors() {
  const p = [];
  for (const [g] of GROUPS) {
    const v = $('mod_' + g).value;
    if (v === 'both') p.push('l' + g, 'r' + g);
    else if (v) p.push(v);
  }
  for (const f of FLAGS) if ($('mod_' + f).checked) p.push(f);
  return p.length ? canonical(p.join('+')) : 'base';
}

function setLayer(l) {
  current = l;
  const p = l.split('+');
  for (const [g] of GROUPS) {
    $('mod_' + g).value = p.includes(g) ? g
      : p.includes('l' + g) && p.includes('r' + g) ? 'both'
        : p.includes('l' + g) ? 'l' + g : p.includes('r' + g) ? 'r' + g : '';
  }
  for (const f of FLAGS) $('mod_' + f).checked = p.includes(f);
  render();
}

for (const [g, label] of GROUPS) {
  const s = el('select', { id: 'mod_' + g, onchange: () => setLayer(layerFromSelectors()) });
  for (const [v, t] of [['', 'なし'], [g, '左右どちらでも'], ['l' + g, '左'], ['r' + g, '右'], ['both', '左右同時']]) {
    s.append(el('option', { value: v, textContent: t }));
  }
  $('mods').append(el('label', {}, label, s));
}
for (const f of FLAGS) {
  const c = el('input', { type: 'checkbox', id: 'mod_' + f, onchange: () => setLayer(layerFromSelectors()) });
  $('extra').append(el('label', {}, c, f.toUpperCase()));
}

/** Marks modifier choices the device's key layout cannot produce. */
function markReachability() {
  for (const [g] of GROUPS) {
    for (const o of $('mod_' + g).options) {
      const parts = o.value === 'both' ? ['l' + g, 'r' + g] : o.value ? [o.value] : [];
      o.textContent = o.textContent.replace(/（この端末にない）$/, '') + (parts.some((p) => !available.has(p)) ? '（この端末にない）' : '');
    }
  }
  for (const f of FLAGS) $('mod_' + f).parentElement.classList.toggle('unavailable', !available.has(f));
}

function renderTabs() {
  available = KCM.availableFromRoles(roles());
  markReachability();
  $('tabs').replaceChildren(...tabLayers().map((l) => {
    const n = Object.keys(map).filter((id) => KCM.layerOf(id) === l).length;
    const b = button(layerName(l), () => setLayer(l), 'tab' + (l === current ? ' active' : ''));
    b.setAttribute('role', 'tab');
    if (n) b.append(el('span', { className: 'badge', textContent: String(n) }));
    return b;
  }));
  const ways = KCM.pressStates(current, available).map((s) => s.how);
  const name = layerName(current);
  $('layerHint').textContent = (current === 'base' ? '修飾キーを押さないときの出力です。'
    : ways.includes('locked') ? `${name}中にキーを押したときの出力です。`
      : ways.includes('tapped') ? `${name}を押したまま（または一度押してから）キーを押したときの出力です。`
        : `${name}を押したままキーを押したときの出力です。`) + (tabLayers().includes(current) ? '' : '（詳細指定）');
}

// --- Keyboard with the current output of every key in the selected layer.

function modifierKey(scan) {
  const code = roles()[scan];
  const parts = current === 'base' ? [] : current.split('+');
  const classes = ['key', 'mod'];
  if ((ROLE_GROUP[code] || []).some((g) => parts.includes(g))) classes.push('held');
  if (code !== klBase[scan]) classes.push('changed');
  if (own(map, 'kl:' + scan)) classes.push('assigned');
  if (selectedMod === scan) classes.push('selected');
  const b = button('', () => { selectedMod = scan; category = 'roles'; render(); }, classes.join(' '));
  b.append(el('small', { textContent: PHYSICAL[scan] }), el('span', { textContent: roleCap(code) }));
  b.title = modName(scan);
  return b;
}

function characterKey(k, kcm, state) {
  const classes = ['key'];
  let cap = { text: '', kind: 'undefined' };
  if (kcm) {
    const r = KCM.evaluate(kcm, k, state.meta);
    cap = state.how === 'held' ? KCM.legend(r) : { text: r.character ? KCM.legend(r).text : '—', kind: 'char' };
    const before = KCM.evaluate(originalKcm, k, state.meta);
    const same = state.how === 'held' ? JSON.stringify(KCM.legend(r)) === JSON.stringify(KCM.legend(before)) &&
      JSON.stringify(r.fallback) === JSON.stringify(before.fallback) : r.character === before.character;
    if (!same) classes.push('changed');
    classes.push(cap.kind);
  }
  if (own(map, current + ':' + k)) classes.push('assigned');
  if (selectedMod === null && k === selected) classes.push('selected');
  if (k === 'SPACE') classes.push('space');
  const b = button('', () => { selected = k; selectedMod = null; render(); }, classes.join(' '));
  b.append(el('small', { textContent: keyName(k) }), el('span', { textContent: cap.text }));
  b.title = keyName(k);
  return b;
}

/** The physical keyboard: character keys show their output in the current layer, modifier keys their role. */
function renderKeyboard() {
  const kcm = shownKcm();
  const state = KCM.pressStates(current, available)[0];
  $('keyboard').replaceChildren(...KCM.LAYOUT.map((row) => el('div', { className: 'keyline' },
    ...row.map((k) => (typeof k !== 'object' ? characterKey(k, kcm, state)
      : k.gap ? el('span', { className: 'gap' }) : modifierKey(String(k.scan)))))));
}

// --- Assignment panel for the selected key.

/** Panel for a physical modifier key: its role, chosen from modifier and ordinary key codes. */
function renderRolePanel(scan) {
  const id = 'kl:' + scan;
  const code = roles()[scan];
  $('target').textContent = modName(scan) + 'の割り当て';
  $('current').textContent = own(map, id) ? `元：${KCM.roleName(klBase[scan])} → 新：${KCM.roleName(code)}`
    : `今の割り当て：${KCM.roleName(code)}（変更なし）`;
  $('reset').disabled = !own(map, id);
  const list = own(map, id) ? KCM.roleWarnings({ scan, code, base: klBase, map: { ...map, [id]: undefined } })
    : [KCM.ROLE_NOTICE];
  if (!klEditable) list.unshift('元のキー配置が保存されていないため、修飾キーの割り当ては変えられません。モジュールを入れ直してください。');
  $('warnings').replaceChildren(...list.map((w) => el('li', { textContent: w })));
  $('pickTarget').classList.toggle('active', capture === 'target');
  $('pickTarget').textContent = capture === 'target' ? 'キーを押してください（もう一度押すと取り消し）' : '押したキーを割り当てる';
  $('fallbackBox').hidden = true;
  $('allCombos').hidden = true;
  if (!ROLE_CATEGORIES.some((c) => c.id === category)) category = 'roles';
  $('cats').replaceChildren(...ROLE_CATEGORIES.map((c) => button(c.label, () => { category = c.id; render(); }, 'tab' + (c.id === category ? ' active' : ''))));
  const cat = ROLE_CATEGORIES.find((c) => c.id === category);
  $('palette').replaceChildren(...cat.codes.map((c) => {
    const b = button(c in ROLE_CAPS ? KCM.roleName(c) : KCM.shortName(c), () => assignRole(scan, c), 'pal' + (code === c ? ' active' : ''));
    b.title = KCM.roleName(c);
    b.disabled = !klEditable;
    return b;
  }));
}

const ROLE_CATEGORIES = [{ id: 'roles', label: '修飾キー', codes: KCM.ROLE_MODIFIERS }, ...KCM.PALETTE];

/** Gives physical modifier key SCAN the role CODE; choosing its original role removes the change. */
function assignRole(scan, code) {
  if (!KCM.validRole('kl:' + scan, code)) { status('この値は割り当てられません。'); return; }
  if (code === klBase[scan]) delete map['kl:' + scan];
  else map['kl:' + scan] = code;
  changed(`${modName(scan)}を${KCM.roleName(code)}に割り当てました。`);
}

function renderPanel() {
  $('panel').hidden = selectedMod === null && selected === null;
  if (selectedMod !== null) { renderRolePanel(selectedMod); return; }
  if (selected === null) return;
  $('fallbackBox').hidden = false;
  $('allCombos').hidden = false;
  if (!CATEGORIES.some((c) => c.id === category)) category = 'cursor';
  const id = current + ':' + selected;
  const state = KCM.pressStates(current, available)[0];
  $('target').textContent = (current === 'base' ? '' : layerName(current) + ' + ') + keyName(selected);
  if (originalKcm) {
    const before = resultText(state.how, KCM.evaluate(originalKcm, selected, state.meta));
    const after = resultText(state.how, KCM.evaluate(shownKcm(), selected, state.meta));
    $('current').textContent = own(map, id) ? `元：${before} → 新：${after}` : `今の出力：${after}（変更なし）`;
  }
  $('reset').disabled = !own(map, id);
  const list = KCM.warnings({ layer: current, key: selected, value: own(map, id) ? map[id] : 'KEEP', available,
    preview: own(map, id) && previewKcm && previewOf === assignmentArgs().join(' ') ? previewKcm : null,
    sameAs: sameAs(current) });
  const companions = sameAs(current);
  if (companions.length) list.unshift('押し方で結果が変わらないよう、' + companions.map(layerName).join('、') + 'にも同じ値を設定します。');
  $('warnings').replaceChildren(...list.map((w) => el('li', { textContent: w })));
  $('pickTarget').classList.toggle('active', capture === 'target');
  $('pickTarget').textContent = capture === 'target' ? 'キーを押してください（もう一度押すと取り消し）' : '押したキーを割り当てる';
  renderPalette(id);
  renderEffective();
}

const CATEGORIES = [...KCM.PALETTE, { id: 'char', label: '文字' }, { id: 'none', label: 'なし' }];

function renderPalette(id) {
  $('cats').replaceChildren(...CATEGORIES.map((c) => button(c.label, () => { category = c.id; render(); }, 'tab' + (c.id === category ? ' active' : ''))));
  const box = $('palette');
  const value = map[id];
  if (category === 'char') {
    const input = el('input', { type: 'text', id: 'char', maxLength: 2, autocomplete: 'off', placeholder: '例：@、あ、[' });
    if (value && value.startsWith('U_')) input.value = String.fromCharCode(parseInt(value.slice(2), 16));
    const set = button('この文字にする', () => {
      if (input.value.length !== 1) { status('1文字だけ入力してください（絵文字など一部の文字は使えません）。'); return; }
      assign('U_' + input.value.charCodeAt(0).toString(16).toUpperCase().padStart(4, '0'));
    });
    box.replaceChildren(el('div', { className: 'charrow' }, input, set));
    return;
  }
  if (category === 'none') {
    box.replaceChildren(button('文字を出さない（キーの入力自体は残る）', () => assign('NONE'), 'pal wide' + (value === 'NONE' ? ' active' : '')));
    return;
  }
  const kind = $('fallback').checked ? 'F' : 'R';
  const cat = KCM.PALETTE.find((c) => c.id === category);
  box.replaceChildren(...cat.codes.map((code) => {
    const b = button(KCM.shortName(code), () => assign(kind + '_' + code), 'pal' + (value === kind + '_' + code ? ' active' : ''));
    b.title = ACTIONS[code];
    return b;
  }));
}

/** Assigns VALUE to the selected key in the current layer and its companion layers. */
function assign(value) {
  if (!validValue(value)) { status('この値は割り当てられません。'); return; }
  for (const l of [current, ...sameAs(current)]) map[l + ':' + selected] = value;
  changed(`${$('target').textContent}を${valueText(value).replace(/^→ /, '')}にしました。`);
}

function unassign(l, key) {
  for (const x of [l, ...sameAs(l, key)]) delete map[x + ':' + key];
}

/** Table of what each modifier combination does on the selected key with the edits applied. */
function renderEffective() {
  const box = $('effective');
  box.replaceChildren();
  if (!originalKcm) return;
  if (previewError) box.append(el('p', { className: 'hint', textContent: 'プレビューできませんでした：' + previewError }));
  const table = el('table');
  for (const row of KCM.effectiveRows(shownKcm(), originalKcm, selected, available)) {
    const tr = el('tr', { className: (row.changed ? 'changed' : '') + (row.layer === current ? ' current' : ''), onclick: () => setLayer(row.layer) });
    const text = row.states.map((s) => (row.states.length > 1 || s.how !== 'held' ? HOW[s.how] + '：' : '') +
      resultText(s.how, s.result) + (s.how === 'held' && s.result.rule ? '（' + s.result.rule.source + '）' : '')).join('\n');
    tr.append(el('th', { textContent: layerName(row.layer) }), el('td', { textContent: text }));
    table.append(tr);
  }
  box.append(table);
}

// --- Touch surface of the keyboard: "tp:mode" in the map, absent for the ROM's own behaviour.

const TOUCH_MODES = [
  { id: 'rom', label: 'ROMの標準', hint: 'キーボードの表面をなぞったときの動き（スクロールなど）は、ROMの標準のままです。' },
  { id: 'off', label: 'オフ', hint: 'キーボードの表面のタッチを使いません。キーを押す操作には影響しません。' },
  { id: 'gesture', label: '独自ジェスチャー', hint: 'なぞる、払う、軽く叩く操作に、割り当てたキーを送ります。' },
];

const THRESHOLD_LABELS = {
  start_mm: ['開始距離', 'mm', 'これだけ動くまで、なぞったとみなしません。最初のキーはここで送ります。'],
  step_mm: ['1回の距離', 'mm', 'なぞり続けるとき、これだけ動くごとにキーを1回送ります。'],
  flick_mm_s: ['払う速さ', 'mm/秒', '動き始めてからの平均の速さがこれ以上なら、払ったとみなします。'],
  tap_ms: ['タップの最大時間', 'ms', '触れてから離すまでがこれ以下なら、タップとみなします。'],
  hold_ms: ['触れてからの待ち時間', 'ms', '触れてからこの時間は、キーを送りません。'],
  gather_ms: ['指をそろえる時間', 'ms', '最初の指からこの時間内に触れた指を、同じ操作の指として数えます。'],
  after_key_ms: ['キー入力後の無視時間', 'ms', 'キーを打ってからこの時間内に始まったタッチは無視します。'],
};

function touchLabel(v) { return TOUCH_MODES.find((m) => m.id === (v || 'rom')).label; }

/** The name of touch setting ID in the change list and the save summary. */
function touchName(id) {
  const name = id.slice(3);
  if (id === 'tp:mode') return 'モード';
  if (own(THRESHOLD_LABELS, name)) return THRESHOLD_LABELS[name][0];
  if (/^[123]_pass$/.test(name)) return name[0] + '本指';
  return KCM.gestureName(id);
}

function isThreshold(id) { return id.startsWith('tp:') && own(THRESHOLD_LABELS, id.slice(3)); }

/** The value of touch setting ID as shown in the change list and the save summary; v may be undefined. */
function touchText(id, v) {
  const name = id.slice(3);
  if (id === 'tp:mode') return touchLabel(v);
  if (isThreshold(id)) {
    if (v !== undefined) return v + ' ' + THRESHOLD_LABELS[name][1];
    const t = touchThresholds.find((x) => x.name === name);
    return t ? `既定（${t.def} ${THRESHOLD_LABELS[name][1]}）` : '既定';
  }
  if (v === undefined) return 'なし';
  if (/^[123]_pass$/.test(name)) return 'ROMの標準の動作に渡す';
  return KCM.touchKeyText(v);
}

/** The gesture assignments of finger count F ("1".."3") in LAYER ("" for the base one), as their IDs. */
function gestureIds(f, layer) { return KCM.TOUCH_GESTURES.map((g) => KCM.gestureId(layer, f, g.id)).filter((id) => own(map, id)); }

/** The gesture assignments of finger count F in every layer. */
function allGestureIds(f) { return KCM.TOUCH_LAYERS.flatMap((l) => gestureIds(f, l.id)); }

/**
 * What gesture G of the selected finger count sends in the selected layer when that layer has no
 * key for it: the base layer's key with the layer's modifier (SYM adds none), or '' if neither has one.
 */
function fallbackText(g) {
  const base = map[KCM.gestureId('', touchFingers, g)];
  if (!touchLayer || !base) return '';
  const { code, mods, once } = KCM.parseTouchKey(base);
  return KCM.touchKeyText(KCM.formatTouchKey(code, touchLayer === 'sym' ? mods : [...mods, touchLayer], once));
}

/** Mode buttons, and in gesture mode the gesture assignments and the thresholds. */
function renderTouch() {
  const mode = map['tp:mode'] || 'rom';
  $('touchModes').replaceChildren(...TOUCH_MODES.map((m) => {
    const b = button(m.label, () => setTouchMode(m.id), 'tab' + (m.id === mode ? ' active' : ''));
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(m.id === mode));
    b.disabled = m.id !== 'rom' && m.id !== mode && touchBlockers.length > 0;
    return b;
  }));
  $('touchHint').textContent = TOUCH_MODES.find((m) => m.id === mode).hint +
    (touchBlockers.length ? `${touchBlockers.join('、')}があるため、切り替えられません。` : '');
  $('gestureEditor').hidden = mode !== 'gesture';
  if (mode === 'gesture') {
    renderFingers();
    renderGesturePanel();
    renderThresholds();
  }
}

function renderFingers() {
  $('layerTabs').replaceChildren(...KCM.TOUCH_LAYERS.map((l) => {
    const b = button(l.label, () => { touchLayer = l.id; touchGesture = null; render(); },
      'tab' + (l.id === touchLayer ? ' active' : '') + (l.id && !available.has(l.id) ? ' unavailable' : ''));
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(l.id === touchLayer));
    const n = ['1', '2', '3'].reduce((sum, f) => sum + gestureIds(f, l.id).length, 0);
    if (n) b.append(el('span', { className: 'badge', textContent: String(n) }));
    return b;
  }));
  const layerLabel = touchLayer && KCM.TOUCH_LAYERS.find((l) => l.id === touchLayer).label;
  $('touchLayerHint').textContent = !touchLayer ? '修飾キーを押していないときの割り当てです。'
    : `${layerLabel}を押している間の割り当てです。割り当てのないジェスチャーは、「なし」のキーを` +
      `${touchLayer === 'sym' ? 'そのまま' : 'この修飾キーを付けて'}送ります（薄い表示）。` +
      (available.has(touchLayer) ? '' : `今のキー配置には${layerLabel}を押せるキーがないため、この割り当ては使われません。`);
  $('fingerTabs').replaceChildren(...['1', '2', '3'].map((f) => {
    const n = gestureIds(f, touchLayer).length;
    const b = button(`${f}本指`, () => { touchFingers = f; touchGesture = null; render(); }, 'tab' + (f === touchFingers ? ' active' : ''));
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-checked', String(f === touchFingers));
    if (own(map, `tp:${f}_pass`)) b.append(el('span', { className: 'badge', textContent: '標準' }));
    else if (n) b.append(el('span', { className: 'badge', textContent: String(n) }));
    return b;
  }));
  const pass = own(map, `tp:${touchFingers}_pass`);
  // Passthrough is per finger count, whatever modifier is held, so it is switched in the base layer.
  $('passFingers').checked = pass;
  $('passFingers').disabled = touchLayer !== '';
  $('passLabel').textContent = `${touchFingers}本指の操作はROMの標準の動作（スクロールなど）に渡す` +
    (touchLayer ? '（「なし」のタブで切り替えます）' : '');
  const cell = (g) => {
    const id = KCM.gestureId(touchLayer, touchFingers, g.id);
    const fallback = own(map, id) ? '' : fallbackText(g.id);
    const b = button('', () => { touchGesture = g.id; render(); },
      'gbtn' + (own(map, id) ? ' assigned' : '') + (touchGesture === g.id ? ' active' : ''));
    b.setAttribute('aria-label', KCM.gestureName(id) + '：' +
      (own(map, id) ? KCM.touchKeyText(map[id]) : fallback ? `割り当てなし（${fallback}を送る）` : '割り当てなし'));
    b.setAttribute('aria-pressed', String(touchGesture === g.id));
    // The group heading names the kind, so a button shows only its direction.
    b.append(el('small', { textContent: KCM.gestureName(id).replace(/^.*本指で(なぞる|払う)?/, '') }),
      el('span', { textContent: own(map, id) ? KCM.touchKeyText(map[id]) : fallback || '—', className: fallback ? 'fallback' : '' }));
    b.disabled = pass;
    return b;
  };
  const row = (kind) => el('div', { className: 'grow' }, ...KCM.TOUCH_GESTURES.filter((g) => g.kind === kind).map(cell));
  $('gestures').replaceChildren(
    el('div', { className: 'glabel', textContent: 'なぞる' }), row('swipe'),
    el('div', { className: 'glabel', textContent: '払う' }), row('flick'),
    el('div', { className: 'glabel', textContent: 'タップ' }), row('tap'));
}

/** The key of the selected gesture: palette, modifiers and removal. */
function renderGesturePanel() {
  const id = touchGesture && KCM.gestureId(touchLayer, touchFingers, touchGesture);
  $('gesturePanel').hidden = !id || own(map, `tp:${touchFingers}_pass`);
  if ($('gesturePanel').hidden) return;
  const { code, mods, once } = KCM.parseTouchKey(map[id]);
  const fallback = own(map, id) ? '' : fallbackText(touchGesture);
  $('gestureTarget').textContent = KCM.gestureName(id) + '：' +
    (own(map, id) ? KCM.touchKeyText(map[id]) : fallback ? `割り当てなし（${fallback}を送る）` : '割り当てなし');
  $('gestureMods').replaceChildren(...['ctrl', 'shift', 'alt', 'meta'].map((m) => {
    const box = el('input', { type: 'checkbox', checked: mods.includes(m), disabled: !own(map, id) });
    box.onchange = () => setGestureKey(id, code, box.checked ? [...mods, m] : mods.filter((x) => x !== m), once);
    return el('label', { className: 'check' }, box, document.createTextNode(m[0].toUpperCase() + m.slice(1)));
  }));
  // Only swipes repeat; flicks and taps send their key once anyway.
  $('gestureOnceBox').hidden = !touchGesture.startsWith('swipe_');
  $('gestureOnce').checked = once;
  $('gestureOnce').disabled = !own(map, id);
  $('gestureOnce').onchange = () => setGestureKey(id, code, mods, $('gestureOnce').checked);
  $('gestureCats').replaceChildren(...KCM.PALETTE.map((c) => button(c.label, () => { touchCategory = c.id; render(); },
    'tab' + (c.id === touchCategory ? ' active' : ''))));
  const cat = KCM.PALETTE.find((c) => c.id === touchCategory) || KCM.PALETTE[0];
  $('gesturePalette').replaceChildren(...cat.codes.map((c) => {
    const b = button(KCM.shortName(c), () => setGestureKey(id, c, mods, once), 'pal' + (code === c ? ' active' : ''));
    b.title = ACTIONS[c] || c;
    return b;
  }));
  $('gestureClear').disabled = !own(map, id);
  $('gestureClear').onclick = () => { delete map[id]; changed(`${KCM.gestureName(id)}の割り当てを外しました。`); };
}

function setGestureKey(id, code, mods, once) {
  map[id] = KCM.formatTouchKey(code, mods, once);
  changed(`${KCM.gestureName(id)}を${KCM.touchKeyText(map[id])}にしました。`);
}

/** The thresholds with touchgestured's defaults as placeholders; an empty field is the default. */
function renderThresholds() {
  if (!touchThresholds.length) {
    $('thresholds').replaceChildren(el('p', { className: 'hint', textContent: 'しきい値の既定値を読み込めませんでした。常駐プログラムがないか、動きません。' }));
    return;
  }
  // Rebuilding the fields would drop the one being typed in, so only values not being edited are refreshed.
  if ($('thresholds').dataset.built !== 'yes') {
    $('thresholds').replaceChildren(...touchThresholds.filter((t) => own(THRESHOLD_LABELS, t.name)).map((t) => {
      const [label, unit, hint] = THRESHOLD_LABELS[t.name];
      const input = el('input', { type: 'text', inputMode: 'decimal', id: 'th_' + t.name, placeholder: String(t.def), autocomplete: 'off' });
      input.oninput = () => setThreshold(t, input, false);
      input.onchange = () => setThreshold(t, input, true);
      return el('label', { className: 'threshold' }, el('span', { textContent: label }),
        el('span', { className: 'thinput' }, input, document.createTextNode(unit)),
        el('small', { textContent: `${hint}（既定 ${t.def}、${t.min}〜${t.max}）` }));
    }));
    $('thresholds').dataset.built = 'yes';
  }
  for (const t of touchThresholds) {
    const input = $('th_' + t.name);
    if (input && document.activeElement !== input) input.value = map['tp:' + t.name] || '';
  }
}

/**
 * Takes a threshold as it is typed (FINAL: the field was left). An invalid value is ignored while
 * typing and put back when the field is left.
 */
function setThreshold(t, input, final) {
  const v = input.value.trim();
  const id = 'tp:' + t.name;
  const [label, unit] = THRESHOLD_LABELS[t.name];
  if (v === '') {
    if (!own(map, id)) return;
    delete map[id];
    thresholdChanged(`${label}を既定値（${t.def} ${unit}）に戻しました。`);
    return;
  }
  if (!KCM.validThreshold(t, v)) {
    if (!final) return;
    input.value = map[id] || '';
    status(`${label}は${t.min}〜${t.max}の${t.integer ? '整数' : '数'}で入力してください。`);
    return;
  }
  if (map[id] === v) return;
  map[id] = v;
  thresholdChanged(`${label}を${v} ${unit}にしました。`);
}

/**
 * Shows a threshold change without the full render(): leaving the field fires its change event on
 * the tap that leaves it, and re-rendering would replace the button being tapped.
 */
function thresholdChanged(msg) {
  renderChanges();
  status(msg + 'しきい値だけの変更は、常駐プログラムが動いていれば、保存するとすぐ効きます。');
}

$('passFingers').onchange = async () => {
  const f = touchFingers;
  const box = $('passFingers');
  if (!box.checked) { delete map[`tp:${f}_pass`]; changed(`${f}本指の操作を独自ジェスチャーに戻しました。`); return; }
  const ids = allGestureIds(f);
  // touchgestured cannot both pass a finger count through and recognise its gestures.
  if (ids.length && !await ask(`${f}本指の割り当て${ids.length}件を外して、ROMの標準の動作に渡しますか？`)) { box.checked = false; return; }
  ids.forEach((id) => delete map[id]);
  map[`tp:${f}_pass`] = 'on';
  touchGesture = null;
  changed(`${f}本指の操作をROMの標準の動作に渡します。`);
};

function setTouchMode(id) {
  if (id === (map['tp:mode'] || 'rom')) return;
  if (id === 'rom') delete map['tp:mode'];
  else map['tp:mode'] = id;
  changed(`キーボードのタッチ操作を${touchLabel(id)}にしました。`);
}

/** Change-list rows: companion assignments (same key and value) are folded into their main row. */
function changeRows() {
  const ids = Object.keys(map).sort();
  const folded = new Set();
  const rows = [];
  for (const id of ids) {
    const [l, key] = id.split(':');
    const with_ = l === 'kl' || l === 'tp' ? [] : sameAs(l, key).filter((c) => map[c + ':' + key] === map[id]);
    with_.forEach((c) => folded.add(c + ':' + key));
    rows.push({ id, l, key, with_ });
  }
  return rows.filter((r) => !folded.has(r.id));
}

function renderChanges() {
  const rows = changeRows();
  const table = $('changes');
  if (!rows.length) { table.replaceChildren(el('tr', {}, el('td', { textContent: '変更なし' }))); return; }
  table.replaceChildren(el('tr', {}, ...['レイヤー', 'キー', '出力', ''].map((t) => el('th', { textContent: t }))),
    ...rows.map(({ id, l, key, with_ }) => {
      if (l === 'kl') {
        const remove = button('✕', (e) => { e.stopPropagation(); delete map[id]; changed(`${modName(key)}をリセットしました。`); }, 'remove');
        remove.title = 'リセット';
        return el('tr', { onclick: () => { selectedMod = key; category = 'roles'; render(); } }, el('td', { textContent: '修飾キー' }),
          el('td', { textContent: PHYSICAL[key] }), el('td', { textContent: valueText(map[id], id) + '（元：' + KCM.roleName(klBase[key]) + '）' }),
          el('td', {}, remove));
      }
      if (l === 'tp') {
        const mode = id === 'tp:mode';
        const remove = button('✕', (e) => {
          e.stopPropagation(); delete map[id];
          changed(mode ? 'キーボードのタッチ操作をROMの標準に戻しました。' : `タッチ操作の${touchName(id)}をリセットしました。`);
        }, 'remove');
        remove.title = 'リセット';
        return el('tr', { onclick: () => $('touch').scrollIntoView() }, el('td', { textContent: 'タッチ操作' }),
          el('td', { textContent: touchName(id) }), el('td', { textContent: touchText(id, map[id]) }), el('td', {}, remove));
      }
      const remove = button('✕', (e) => { e.stopPropagation(); unassign(l, key); changed(`${layerName(l)} + ${keyName(key)}をリセットしました。`); }, 'remove');
      remove.title = 'リセット';
      return el('tr', { onclick: () => { selected = key; selectedMod = null; setLayer(l); } },
        el('td', { textContent: layerName(l) + (with_.length ? '（' + with_.map(layerName).join('、') + 'も）' : '') }),
        el('td', { textContent: keyName(key) }),
        el('td', { textContent: valueText(map[id]) }), el('td', {}, remove));
    }));
}

function render() {
  renderTabs();
  renderKeyboard();
  renderPanel();
  renderTouch();
  renderChanges();
}

function changed(msg) {
  render();
  status(msg + '保存すると再起動後に反映されます。');
  refreshPreview();
}

/** Regenerates the map with the current edits (remap.sh preview). */
async function refreshPreview() {
  const mine = ++previewSeq;
  const args = assignmentArgs();
  try {
    const out = await bridge(['preview', ...args]);
    if (mine !== previewSeq) return;
    previewKcm = parseKcm(out);
    previewOf = args.join(' ');
    previewError = '';
  } catch (e) {
    if (mine !== previewSeq) return;
    previewKcm = null;
    previewError = e.message;
  }
  render();
}

function renderDiagnostics(st) {
  $('diagnostics').replaceChildren(...KCM.diagnose(st).map((d) => el('li', { textContent: d.text, className: d.warn ? 'warn' : '' })));
}

/** Reads remap.sh status, updates the pressable modifiers and the diagnostics panel. */
async function loadStatus() {
  const st = KCM.parseStatus(await bridge(['status']));
  klBase = st.klBase;
  klLive = st.klLive;
  klEditable = st.klEditable;
  touchBlockers = [...st.tpForeign, ...st.tpConflicts.map((m) => 'モジュール' + m)];
  touchThresholds = st.tpThresholds;
  $('thresholds').dataset.built = '';
  renderDiagnostics(st);
}

// --- Key capture: pick the key to edit, or the key to send, by pressing it.

function setCapture(mode) {
  capture = capture === mode ? '' : mode;
  $('pickSource').classList.toggle('active', capture === 'source');
  $('pickSource').textContent = capture === 'source' ? 'キーを押してください（もう一度押すと取り消し）' : 'キーを押して選ぶ';
  if (capture) {
    // A focused text field routes hardware keys through the IME, which reports every key as
    // "Unidentified" (keyCode 229); a non-editable element receives the real key events.
    if (document.activeElement && document.activeElement !== document.body) document.activeElement.blur();
    $('keyboard').focus({ preventScroll: true });
    status('キーを押してください。届くのは、いま有効な設定が適用された後のキーです。');
  }
  render();
}
$('pickSource').onclick = () => setCapture('source');
$('pickTarget').onclick = () => setCapture('target');
document.addEventListener('keydown', (e) => {
  if (!capture || e.target === $('keytest')) return;
  if (e.keyCode === 229) { status('入力欄が選ばれていると、キーを識別できません。入力欄の外を押してから、もう一度キーを押してください。'); return; }
  const mode = capture;
  if (mode === 'source') {
    const key = KCM.editableKeyOf(e);
    // A modifier key is found by its live role, which is what the WebView reports.
    const scan = Object.keys(klLive).find((s) => klLive[s] === MODIFIER_CODES[e.code]);
    if (!key && !scan) { status(`「${e.key}」は編集できないキーです。`); return; }
    e.preventDefault();
    capture = '';
    if (key) { selected = key; selectedMod = null; } else selectedMod = scan;
    setCapture('');
    status(`${key ? keyName(key) : modName(scan)}を選びました。`);
  } else {
    const code = selectedMod !== null ? MODIFIER_CODES[e.code] || KCM.keyCodeOf(e) : KCM.keyCodeOf(e);
    if (!code || !(own(ACTIONS, code) || (selectedMod !== null && KCM.ROLE_MODIFIERS.includes(code)))) {
      if (!MODIFIER_CODES[e.code]) status(`「${e.key}」は割り当てられないキーです。`);
      return;
    }
    e.preventDefault();
    capture = '';
    setCapture('');
    if (selectedMod !== null) assignRole(selectedMod, code);
    else assign(($('fallback').checked ? 'F_' : 'R_') + code);
  }
}, true);

$('fallback').onchange = render;
$('reset').onclick = () => {
  if (selectedMod !== null) { delete map['kl:' + selectedMod]; changed(`${modName(selectedMod)}をリセットしました。`); return; }
  unassign(current, selected);
  changed(`${$('target').textContent}をリセットしました。`);
};
$('resetLayer').onclick = async () => {
  if (!await ask(`${layerName(current)}レイヤーの変更をすべてリセットしますか？`)) return;
  for (const id of Object.keys(map)) {
    if (KCM.layerOf(id) !== current) continue;
    const [l, key] = id.split(':');
    if (l === 'kl') delete map[id];
    else unassign(l, key);
  }
  changed('このレイヤーをリセットしました。');
};
$('resetAll').onclick = async () => {
  if (!await ask('すべての変更をリセットしますか？')) return;
  map = Object.create(null);
  changed('すべてリセットしました。');
};
$('export').onclick = () => {
  $('backup').value = JSON.stringify(map, null, 2);
  $('backup').focus();
  $('backup').select();
};
$('import').onclick = async () => {
  let m;
  try {
    m = validate(JSON.parse($('backup').value));
  } catch (e) {
    status('読み込めませんでした：' + e.message);
    return;
  }
  if (!await ask('現在の編集内容を読み込んだ設定で置き換えますか？')) return;
  map = m;
  changed('設定を読み込みました。');
};
$('save').onclick = async () => {
  try {
    map = validate(map);
    const args = assignmentArgs();
    if (args.join(' ').length > 90000) throw new Error('設定が大きすぎます。');
    const diff = KCM.diffAssignments(saved, map);
    if (!diff.length) { status('保存済みの設定から変わっていません。'); return; }
    const lines = diff.map((d) => {
      const [l, key] = d.id.split(':');
      if (l === 'kl') return `${modName(key)}の割り当て：${KCM.roleName(d.from || klBase[key])} → ${KCM.roleName(d.to || klBase[key])}`;
      if (l === 'tp') return `キーボードのタッチ操作${key === 'mode' ? '' : `（${touchName(d.id)}）`}：${touchText(d.id, d.from)} → ${touchText(d.id, d.to)}`;
      const plain = (v) => valueText(v).replace(/^→ /, '');
      return `${layerName(l)} + ${keyName(key)}：${plain(d.from)} → ${plain(d.to)}`;
    });
    // Thresholds are read by touchgestured, which save restarts; everything else is read at boot.
    const onlyThresholds = diff.every((d) => isThreshold(d.id));
    const when = onlyThresholds ? '常駐プログラムが動いていれば、すぐ効きます。' : '再起動後に反映されます。';
    if (!await ask('次の' + diff.length + '件を保存します。' + when + '\n\n' + lines.join('\n'))) return;
    $('editor').disabled = true;
    const out = await bridge(['save', ...args]);
    saved = Object.assign(Object.create(null), map);
    const warnings = out.split('\n').filter((l) => l.startsWith('WARNING:')).map((l) => l.replace(/^WARNING: */, '注意：'));
    status('保存しました。' + (onlyThresholds ? when : '再起動すると反映されます。') + (warnings.length ? '\n' + warnings.join('\n') : ''));
    if (!onlyThresholds && await ask('保存しました。再起動すると反映されます。今すぐ再起動しますか？', '再起動する', 'あとで')) {
      status('再起動しています…');
      // The device goes down before remap.sh can answer, so no reply is awaited.
      bridge(['reboot']).catch((e) => status('再起動できませんでした：' + e.message));
    }
  } catch (e) {
    status('保存できませんでした：' + e.message);
  } finally {
    $('editor').disabled = false;
  }
};
$('recheck').onclick = async () => {
  try {
    await loadStatus();
    render();
    status('診断を更新しました。');
  } catch (e) {
    status('診断できませんでした：' + e.message);
  }
};

// Shows the key events the WebView receives, to check a saved map after rebooting. The test area
// is a focusable non-editable element: in a text field the IME would hide the keys (keyCode 229).
$('keytest').onkeydown = (e) => {
  e.preventDefault();
  const mods = ['Shift', 'Alt', 'Control', 'Meta', 'CapsLock', 'SymbolLock'].filter((m) => e.getModifierState(m));
  const line = `key=${JSON.stringify(e.key)} code=${e.code || '-'} keyCode=${e.keyCode}` + (mods.length ? ' [' + mods.join('+') + ']' : '');
  $('keylog').textContent = [line, ...$('keylog').textContent.split('\n').filter(Boolean)].slice(0, 12).join('\n');
};

(async () => {
  try {
    originalKcm = parseKcm(await bridge(['original']));
    const m = Object.create(null);
    for (const s of (await bridge(['read'])).split(/\r?\n/)) {
      if (!s) continue;
      const [id, v] = s.split('=');
      if (own(m, id)) throw new Error('保存済みの割り当てが重複しています。');
      m[id] = v;
    }
    map = validate(m);
    saved = Object.assign(Object.create(null), map);
    await loadStatus();
    setLayer(current);
    $('editor').disabled = false;
    status('読み込みました。レイヤーとキーを選び、パレットから出力を選んでください。');
    refreshPreview();
  } catch (e) {
    status('読み込めませんでした：' + e.message);
  }
})();
