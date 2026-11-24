'use strict';
/*
 * Pure logic of the WebUI: assignment validation, reading a KCM and evaluating key events with
 * Android 16's rules (frameworks/native libs/input/KeyCharacterMap.cpp).
 * Loaded as a classic script (global KCM) by index.html and with require() by the Node tests.
 * A classic script, not an ES module, so loading does not depend on the MIME type WebUI X
 * serves for module scripts.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.KCM = api;
})(this, function () {
  const META = {
    SHIFT: 0x1, ALT: 0x2, SYM: 0x4, FUNCTION: 0x8, ALT_LEFT: 0x10, ALT_RIGHT: 0x20,
    SHIFT_LEFT: 0x40, SHIFT_RIGHT: 0x80, CTRL: 0x1000, CTRL_LEFT: 0x2000, CTRL_RIGHT: 0x4000,
    META: 0x10000, META_LEFT: 0x20000, META_RIGHT: 0x40000,
    CAPS_LOCK: 0x100000, NUM_LOCK: 0x200000, SCROLL_LOCK: 0x400000,
  };
  /** KCM modifier names and their meta bits, as in AOSP's modifiers[] table. */
  const MODIFIERS = {
    shift: META.SHIFT, lshift: META.SHIFT_LEFT, rshift: META.SHIFT_RIGHT,
    alt: META.ALT, lalt: META.ALT_LEFT, ralt: META.ALT_RIGHT,
    ctrl: META.CTRL, lctrl: META.CTRL_LEFT, rctrl: META.CTRL_RIGHT,
    meta: META.META, lmeta: META.META_LEFT, rmeta: META.META_RIGHT,
    sym: META.SYM, fn: META.FUNCTION,
    capslock: META.CAPS_LOCK, numlock: META.NUM_LOCK, scrolllock: META.SCROLL_LOCK,
  };
  /** Canonical spelling order of modifiers in saved assignments (same as patch.awk). */
  const ORDER = Object.keys(MODIFIERS);
  const GROUPS = ['shift', 'alt', 'ctrl', 'meta'];

  /** Physical KEY2 keys by row, as KCM key code labels. */
  const ROWS = [
    'QWERTYUIOP'.split(''),
    'ASDFGHJKL'.split('').concat('DEL'),
    'ZXCVBNM'.split('').concat('4', 'ENTER'),
    ['0', 'SPACE'],
  ];
  const KEYS = ROWS.flat();

  /** The KEY2's physical modifier keys: scan code -> printed name. */
  const PHYSICAL = { 42: '⇧', 56: 'alt', 100: 'sym', 110: 'Speed' };
  /**
   * Physical keyboard drawing, ten key widths per row: KCM key labels, {scan} for modifier keys
   * and {gap} for empty space. The bottom row is inset one key width on each side; Space is four.
   */
  const LAYOUT = [
    ROWS[0],
    ROWS[1],
    [{ scan: 56 }, ...'ZXCVBNM'.split(''), '4', 'ENTER'],
    [{ gap: 1 }, { scan: 42 }, '0', 'SPACE', { scan: 100 }, { scan: 110 }, { gap: 1 }],
  ];
  /** Modifier key codes a physical modifier key can take (klpatch.awk accepts these and ACTIONS). */
  const ROLE_MODIFIERS = ['SHIFT_LEFT', 'SHIFT_RIGHT', 'ALT_LEFT', 'ALT_RIGHT', 'CTRL_LEFT', 'CTRL_RIGHT',
    'META_LEFT', 'META_RIGHT', 'SYM', 'FUNCTION', 'CAPS_LOCK'];
  const ROLE_NAMES = { SHIFT_LEFT: '左Shift', SHIFT_RIGHT: '右Shift', ALT_LEFT: '左Alt', ALT_RIGHT: '右Alt',
    CTRL_LEFT: '左Ctrl', CTRL_RIGHT: '右Ctrl', META_LEFT: '左Meta', META_RIGHT: '右Meta', SYM: 'SYM',
    FUNCTION: 'Fn', CAPS_LOCK: 'CapsLock' };

  /** Key codes offered for replace/fallback, with display names (patch.awk accepts the same set). */
  const ACTIONS = {
    DPAD_LEFT: 'カーソル左（←）', DPAD_DOWN: 'カーソル下（↓）', DPAD_UP: 'カーソル上（↑）', DPAD_RIGHT: 'カーソル右（→）', DPAD_CENTER: '決定',
    TAB: 'Tab', ESCAPE: 'Esc', MOVE_HOME: 'Home（行頭）', MOVE_END: 'End（行末）', PAGE_UP: 'Page Up',
    PAGE_DOWN: 'Page Down', INSERT: 'Insert', FORWARD_DEL: 'Delete', DEL: 'Backspace',
    ENTER: 'Enter', SPACE: 'Space', LANGUAGE_SWITCH: 'IME切替',
    SWITCH_CHARSET: '文字セット切替', BACK: '戻る', MENU: 'メニュー', SEARCH: '検索',
    HOME: 'ホーム画面',
  };
  for (const c of 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') ACTIONS[c] = c;
  for (const k of ['COMMA', 'PERIOD', 'MINUS', 'EQUALS', 'LEFT_BRACKET', 'RIGHT_BRACKET',
    'BACKSLASH', 'SEMICOLON', 'APOSTROPHE', 'SLASH', 'GRAVE', 'AT', 'POUND', 'PLUS', 'STAR']) {
    ACTIONS[k] = k;
  }
  for (let i = 1; i <= 12; i++) ACTIONS['F' + i] = 'F' + i;

  const own = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

  /**
   * Canonical spelling of a modifier layer ("base" or names joined by "+"), or '' if invalid.
   * Mixing a general modifier with its own left/right form is rejected, like patch.awk.
   */
  function canonical(s) {
    if (s === 'base') return s;
    const p = s.split('+');
    if (p.some((x) => !ORDER.includes(x)) || new Set(p).size !== p.length) return '';
    for (const g of GROUPS) if (p.includes(g) && (p.includes('l' + g) || p.includes('r' + g))) return '';
    return ORDER.filter((x) => p.includes(x)).join('+');
  }

  /** Whether VALUE (R_KEY, F_KEY, U_XXXX or NONE) is an assignable behaviour. */
  function validValue(v) {
    if (typeof v !== 'string') return false;
    if (v === 'NONE') return true;
    if (/^[RF]_/.test(v)) return own(ACTIONS, v.slice(2));
    if (/^U_[0-9A-F]{4}$/.test(v)) {
      const n = parseInt(v.slice(2), 16);
      return n !== 0 && !(n >= 0xd800 && n <= 0xdfff);
    }
    return false;
  }

  /** Whether ID ("kl:SCAN") and VALUE (a key code label) are a valid modifier key role. */
  function validRole(id, v) {
    const m = /^kl:([0-9]+)$/.exec(id);
    return !!m && own(PHYSICAL, m[1]) && typeof v === 'string' && (ROLE_MODIFIERS.includes(v) || own(ACTIONS, v));
  }

  // remap.sh's grammar for a threshold; the length also keeps a settings line under its 256 bytes.
  const THRESHOLD_FORM = /^[0-9]{1,5}(\.[0-9]{1,6})?$/;
  const TOUCH_THRESHOLDS = ['start_mm', 'step_mm', 'flick_mm_s', 'tap_ms', 'hold_ms', 'gather_ms', 'after_key_ms'];
  const TOUCH_GESTURE = /^tp:((shift|alt|ctrl|sym)_)?[123]_(swipe_(up|down|left|right)|flick_(up|down|left|right|upleft|upright|downleft|downright)|tap)$/;
  /** Gesture layers: while the physical modifier is held, its layer's gesture keys are used. */
  const TOUCH_LAYERS = [{ id: '', label: 'なし' }, { id: 'shift', label: 'Shift' }, { id: 'alt', label: 'Alt' },
    { id: 'ctrl', label: 'Ctrl' }, { id: 'sym', label: 'SYM' }];
  const TOUCH_MODIFIERS = ['ctrl', 'shift', 'alt', 'meta'];

  /**
   * Whether ID and VALUE are a touch surface setting: tp:mode (off or gesture), a threshold, a
   * gesture's key (KEYCODE[+MODIFIER...]) or a passthrough finger count. remap.sh checks ranges and
   * key code labels again on the files it generates.
   */
  function validTouch(id, v) {
    if (typeof v !== 'string') return false;
    if (id === 'tp:mode') return v === 'off' || v === 'gesture';
    if (TOUCH_THRESHOLDS.includes(id.slice(3))) return THRESHOLD_FORM.test(v);
    if (/^tp:[123]_pass$/.test(id)) return v === 'on';
    if (!TOUCH_GESTURE.test(id)) return false;
    const [code, ...mods] = v.split('+');
    return /^[A-Z0-9][A-Z0-9_]*$/.test(code) && mods.every((m, i) => TOUCH_MODIFIERS.includes(m) && mods.indexOf(m) === i);
  }

  const ARROWS = { up: '↑', down: '↓', left: '←', right: '→', upleft: '↖', upright: '↗', downleft: '↙', downright: '↘' };
  /** The gestures of one finger count, as the page lists them: {id ("swipe_up"), kind, dir}. */
  const TOUCH_GESTURES = [
    ...['up', 'down', 'left', 'right'].map((dir) => ({ id: 'swipe_' + dir, kind: 'swipe', dir })),
    ...['up', 'down', 'left', 'right', 'upleft', 'upright', 'downleft', 'downright'].map((dir) => ({ id: 'flick_' + dir, kind: 'flick', dir })),
    { id: 'tap', kind: 'tap', dir: '' },
  ];
  const TOUCH_KINDS = { swipe: 'なぞる', flick: '払う', tap: 'タップ' };

  /** The setting ID of gesture G ("flick_upleft") of FINGERS ("2") in LAYER ("" or "shift"). */
  function gestureId(layer, fingers, g) { return `tp:${layer ? layer + '_' : ''}${fingers}_${g}`; }

  /** "Shift＋2本指で払う↖" for a gesture setting ID such as "tp:shift_2_flick_upleft". */
  function gestureName(id) {
    const m = /^tp:(?:(shift|alt|ctrl|sym)_)?([123])_(.*)$/.exec(id);
    const g = m && TOUCH_GESTURES.find((x) => x.id === m[3]);
    if (!g) return id;
    const layer = m[1] ? TOUCH_LAYERS.find((l) => l.id === m[1]).label + '＋' : '';
    return `${layer}${m[2]}本指で${TOUCH_KINDS[g.kind]}${ARROWS[g.dir] || ''}`;
  }

  /** A gesture's key value "CODE[+mod...]" as {code, mods}; mods in TOUCH_MODIFIERS order. */
  function parseTouchKey(v) {
    const [code, ...mods] = (v || '').split('+');
    return { code, mods: TOUCH_MODIFIERS.filter((m) => mods.includes(m)) };
  }

  /** The value for key CODE with modifiers MODS, which may come in any order. */
  function formatTouchKey(code, mods) {
    return [code, ...TOUCH_MODIFIERS.filter((m) => mods.includes(m))].join('+');
  }

  /** "Ctrl+Shift+←" for a gesture's key value. */
  function touchKeyText(v) {
    const { code, mods } = parseTouchKey(v);
    return [...mods.map((m) => MODIFIER_NAMES[m]), shortName(code)].join('+');
  }

  /**
   * Whether text is acceptable for threshold T ({min, max, integer} from touchgestured): a plain
   * number in range, whole where the table says so.
   */
  function validThreshold(t, text) {
    if (!THRESHOLD_FORM.test(text)) return false;
    const v = Number(text);
    return v >= t.min && v <= t.max && (!t.integer || Number.isInteger(v));
  }

  /** Whether ID ("layer:KEY") names a canonical layer and a KEY2 key. */
  function validId(id) {
    const p = id.split(':');
    return p.length === 2 && canonical(p[0]) !== '' && canonical(p[0]) === p[0] && KEYS.includes(p[1]);
  }

  /** Checks a whole assignment map {"layer:KEY": VALUE}; returns a prototype-free copy or throws. */
  function validate(obj) {
    if (!obj || typeof obj !== 'object' || Array.isArray(obj) || Object.keys(obj).length > 1500) {
      throw new Error('設定の形式が正しくないか、件数が上限（1500件）を超えています。');
    }
    const out = Object.create(null);
    for (const [id, v] of Object.entries(obj)) {
      const ok = id.startsWith('kl:') ? validRole(id, v) : id.startsWith('tp:') ? validTouch(id, v) : validId(id) && validValue(v);
      if (!ok) throw new Error('読み込めない割り当てがあります：' + id);
      out[id] = v;
    }
    // touchgestured refuses a finger count that is both passed through and given gestures.
    for (const f of ['1', '2', '3']) {
      if (out[`tp:${f}_pass`] && TOUCH_LAYERS.some((l) => TOUCH_GESTURES.some((g) => own(out, gestureId(l.id, f, g.id))))) {
        throw new Error(`${f}本指は、ROMの標準の動作に渡す設定とジェスチャーの割り当てを同時には持てません。`);
      }
    }
    return out;
  }

  const ESCAPES = { n: 10, t: 9, '\\': 92, "'": 39, '"': 34 };

  /** Reads one behaviour list ("'a' fallback TAB", "replace DPAD_LEFT", ...) of a checked KCM line. */
  function parseBehavior(s, where) {
    const b = { character: 0, fallback: null, replace: null };
    let i = 0;
    const ws = () => { while (i < s.length && ' \t\r'.includes(s[i])) i++; };
    const token = () => { const start = i; while (i < s.length && !' \t\r'.includes(s[i])) i++; return s.slice(start, i); };
    for (ws(); i < s.length && s[i] !== '#'; ws()) {
      if (s[i] === "'") {
        let c = s[i + 1];
        let len = 3;
        if (c === '\\') {
          const e = s[i + 2];
          if (e === 'u') { c = parseInt(s.slice(i + 3, i + 7), 16); len = 8; } else { c = ESCAPES[e]; len = 4; }
        } else {
          c = c.charCodeAt(0);
        }
        if (!c || s[i + len - 1] !== "'") throw new Error(where + ': unreadable character literal');
        b.character = c;
        i += len;
      } else {
        const t = token();
        if (t === 'none') b.character = 0;
        else if (t === 'fallback') { ws(); b.fallback = token(); }
        else if (t === 'replace') { ws(); b.replace = token(); }
        else throw new Error(where + ': unexpected behaviour ' + t);
      }
    }
    return b;
  }

  /**
   * Reads a KCM that already passed lint.awk (the generator output or the original).
   * Returns {type, keys: {LABEL: {label, behaviors}}} where behaviors are in AOSP lookup order
   * (the parser pushes each rule to the front, so later rules are tried first).
   */
  function parseKcm(text) {
    const kcm = { type: '', keys: Object.create(null) };
    let key = null;
    text.split('\n').forEach((raw, n) => {
      const where = 'line ' + (n + 1);
      const line = raw.replace(/^[ \t\r]+/, '');
      if (line === '' || line[0] === '#') return;
      if (key === null) {
        const w = line.split(/[ \t\r]+/);
        if (w[0] === 'type') kcm.type = w[1];
        else if (w[0] === 'key') kcm.keys[w[1]] = key = { label: 0, behaviors: [] };
        else if (w[0] !== 'map') throw new Error(where + ': unexpected ' + w[0]);
        return;
      }
      if (/^\}([ \t\r]|$)/.test(line)) { key = null; return; }
      const colon = line.indexOf(':');
      const behavior = parseBehavior(line.slice(colon + 1), where);
      for (const prop of line.slice(0, colon).split(',').map((p) => p.trim())) {
        if (prop === 'label') key.label = behavior.character;
        else if (prop !== 'number') {
          const meta = prop === 'base' ? 0 : prop.split('+').reduce((m, x) => m | MODIFIERS[x], 0);
          key.behaviors.unshift({ meta, ...behavior, source: prop, line: n + 1 });
        }
      }
    });
    return kcm;
  }

  /** AOSP KeyCharacterMap::matchesMetaState. */
  function matchesMetaState(event, rule) {
    if ((event & rule) !== rule) return false;
    let unmatched = event & ~rule & (META.CTRL | META.CTRL_LEFT | META.CTRL_RIGHT |
      META.ALT | META.ALT_LEFT | META.ALT_RIGHT | META.META | META.META_LEFT | META.META_RIGHT);
    for (const [general, left, right] of [[META.CTRL, META.CTRL_LEFT, META.CTRL_RIGHT],
      [META.ALT, META.ALT_LEFT, META.ALT_RIGHT], [META.META, META.META_LEFT, META.META_RIGHT]]) {
      if (rule & general) unmatched &= ~(left | right);
      else if (rule & (left | right)) unmatched &= ~general;
    }
    return !unmatched;
  }

  /** AOSP normalizeMetaState: a left/right bit implies its general bit. */
  function normalizeMetaState(m) {
    for (const [general, left, right] of [[META.ALT, META.ALT_LEFT, META.ALT_RIGHT],
      [META.SHIFT, META.SHIFT_LEFT, META.SHIFT_RIGHT], [META.CTRL, META.CTRL_LEFT, META.CTRL_RIGHT],
      [META.META, META.META_LEFT, META.META_RIGHT]]) {
      if (m & (left | right)) m |= general;
    }
    return m;
  }

  /**
   * What Android does for KEY (a KCM key label) pressed with META (meta bits): the rule found,
   * the resulting key and meta state (applyKeyBehavior), the character (getCharacter) and the
   * fallback action (getFallbackAction; null if none).
   */
  function evaluate(kcm, key, meta) {
    const k = kcm.keys[key];
    const rule = k ? k.behaviors.find((b) => matchesMetaState(meta, b.meta)) || null : null;
    const result = { rule, key, meta, character: rule ? rule.character : 0, fallback: null };
    if (rule && rule.replace) {
      let m = meta & ~rule.meta;
      for (const [general, left, right] of [[META.ALT, META.ALT_LEFT, META.ALT_RIGHT],
        [META.CTRL, META.CTRL_LEFT, META.CTRL_RIGHT], [META.SHIFT, META.SHIFT_LEFT, META.SHIFT_RIGHT]]) {
        if (rule.meta & general) m &= ~(left | right);
        if (rule.meta & (left | right)) m &= ~general;
      }
      result.key = rule.replace;
      result.meta = normalizeMetaState(m);
    }
    if (rule && rule.fallback) result.fallback = { key: rule.fallback, meta: meta & ~rule.meta };
    return result;
  }

  const SIDES = [['shift', 'SHIFT_LEFT', 'SHIFT_RIGHT'], ['alt', 'ALT_LEFT', 'ALT_RIGHT'],
    ['ctrl', 'CTRL_LEFT', 'CTRL_RIGHT'], ['meta', 'META_LEFT', 'META_RIGHT']];

  /**
   * Modifier names (keys of MODIFIERS) the device can produce, given the modifier key codes of
   * its key layout (remap.sh status "modifier=" lines, e.g. ["SHIFT_LEFT", "ALT_LEFT", "SYM"]).
   * The returned set also holds those key codes, so CAPS_LOCK tells a real Caps Lock key apart.
   */
  function availableModifiers(klKeys) {
    const has = (k) => klKeys.includes(k);
    const set = new Set(klKeys);
    for (const [g, left, right] of SIDES) {
      if (has(left)) set.add('l' + g);
      if (has(right)) set.add('r' + g);
      if (has(left) || has(right)) set.add(g);
    }
    if (has('SYM')) set.add('sym');
    if (has('FUNCTION')) set.add('fn');
    // A locked (double-tapped) Shift reaches character rules as CAPS_LOCK in the framework's
    // text input path (MetaKeyKeyListener + KeyEvent.normalizeMetaState).
    if (has('CAPS_LOCK') || set.has('shift')) set.add('capslock');
    if (has('NUM_LOCK')) set.add('numlock');
    if (has('SCROLL_LOCK')) set.add('scrolllock');
    return set;
  }

  /** Modifiers of a canonical layer the device cannot produce. */
  function unreachableParts(layer, available) {
    return layer === 'base' ? [] : layer.split('+').filter((p) => !available.has(p));
  }

  /**
   * Ways of pressing LAYER's modifiers and the meta state each gives: [{how, meta}].
   * - held: keys held down (side bit plus general bit; a general modifier uses the left key
   *   when the device has one). Character, replace and fallback rules all apply.
   * - tapped: Shift/Alt/SYM tapped beforehand. The framework's text path adds them as general
   *   bits and only looks up the character; replace and fallback do not apply.
   * - locked: Caps Lock coming from a locked Shift on a device without a Caps Lock key; also
   *   characters only.
   */
  function pressStates(layer, available) {
    if (layer === 'base') return [{ how: 'held', meta: 0 }];
    let held = 0;
    let tapped = 0;
    let tappable = false;
    let locked = false;
    for (const p of layer.split('+')) {
      const side = SIDES.find(([g]) => p === g || p === 'l' + g || p === 'r' + g);
      if (side) {
        const [g] = side;
        const bit = MODIFIERS[p !== g ? p : available.has('l' + g) || !available.has('r' + g) ? 'l' + g : 'r' + g];
        held |= MODIFIERS[g] | bit;
        if (p === g && (g === 'shift' || g === 'alt')) {
          tapped |= MODIFIERS[g];
          tappable = true;
        } else {
          tapped |= MODIFIERS[g] | bit;
        }
      } else {
        if (p === 'sym') tappable = true;
        if (p === 'capslock' && !available.has('CAPS_LOCK')) locked = true;
        held |= MODIFIERS[p];
        tapped |= MODIFIERS[p];
      }
    }
    if (locked) return [{ how: 'locked', meta: tapped }];
    const states = [{ how: 'held', meta: held }];
    if (tappable) states.push({ how: 'tapped', meta: tapped });
    return states;
  }

  /**
   * Layers that must get the same value as LAYER on KEY so that every way of pressing it gives
   * the same result: side-specific forms of LAYER's general modifiers (e.g. "lalt" for "alt")
   * that the device can produce and that already have a rule (SOURCES, canonical layers).
   * Held Alt matches such a narrower rule first, tapped Alt only matches the general one.
   */
  function companions(layer, sources, available) {
    if (layer === 'base') return [];
    let candidates = [[]];
    for (const p of layer.split('+')) {
      const forms = SIDES.some(([g]) => g === p) ? [p, 'l' + p, 'r' + p] : [p];
      candidates = candidates.flatMap((c) => forms.map((f) => c.concat(f)));
    }
    return candidates.map((c) => canonical(c.join('+')))
      .filter((c) => c && c !== layer && sources.has(c) && unreachableParts(c, available).length === 0);
  }

  /** Canonical layers that have a rule for KEY in KCM. */
  function ruleLayers(kcm, key) {
    const k = kcm.keys[key];
    return new Set(k ? k.behaviors.map((b) => canonical(b.source)).filter(Boolean) : []);
  }

  /** Whether two evaluate() results are the same; only characters matter for tapped/locked states. */
  function sameResult(how, a, b) {
    if (how !== 'held') return a.character === b.character;
    return a.key === b.key && a.meta === b.meta && a.character === b.character &&
      JSON.stringify(a.fallback) === JSON.stringify(b.fallback);
  }

  /**
   * One row per combination of the device's modifiers (general names), with what pressing it
   * does on KEY in KCM and whether that differs from ORIGINAL.
   * Rows: {layer, states: [{how, meta, result}], changed}.
   */
  function effectiveRows(kcm, original, key, available) {
    const groups = ['shift', 'alt', 'ctrl', 'meta', 'sym', 'fn'].filter((g) => available.has(g));
    const layers = [];
    for (let mask = 0; mask < 1 << groups.length; mask++) {
      layers.push(groups.filter((g, i) => mask & (1 << i)).join('+') || 'base');
    }
    if (available.has('capslock')) layers.push('capslock');
    return layers.map((layer) => {
      const states = pressStates(layer, available).map((s) => ({ ...s, result: evaluate(kcm, key, s.meta) }));
      const changed = states.some((s) => !sameResult(s.how, s.result, evaluate(original, key, s.meta)));
      return { layer, states, changed };
    });
  }

  /**
   * Cautions for assigning VALUE ("KEEP" to reset) to LAYER on KEY. PREVIEW, when given, is the
   * map generated with the edit; it reveals edits hidden by a narrower rule. SAMEAS lists the
   * companion layers written with the same value.
   */
  function warnings({ layer, key, value, available, preview, sameAs = [] }) {
    const out = [];
    const missing = unreachableParts(layer, available);
    if (missing.length) out.push(`この端末では押せない修飾（${missing.map(modifierLabel).join('、')}）を含むため、保存しても使えません。`);
    if (value === 'KEEP') return out;
    const parts = layer === 'base' ? [] : layer.split('+');
    const states = pressStates(layer, available);
    const characterValue = value === 'NONE' || value.startsWith('U_');
    if (layer === 'base' || layer === 'shift' || layer === 'capslock') out.push('通常の文字入力が変わります。');
    if (parts.length === 1 && /^[lr]?ctrl$/.test(parts[0]) && key.length === 1 && 'ACVXZ'.includes(key)) {
      out.push(`Ctrl+${key}はコピーや貼り付けなどに使われることが多い組み合わせです。`);
    }
    if (key === 'SPACE' && parts.some((p) => /^[lr]?alt$/.test(p))) out.push('Alt+SpaceはIMEの入力切替などに使われることがあります。');
    if (!characterValue && states.some((s) => s.how !== 'held')) {
      out.push('キーの置き換えとフォールバックは、押したままの入力にだけ効きます。一度押しやShiftロックでは文字だけが使われます。');
    }
    if (preview) {
      for (const s of states) {
        if (s.how !== 'held' && !characterValue) continue;
        const rule = evaluate(preview, key, s.meta).rule;
        const by = rule ? canonical(rule.source) : '';
        if (by !== layer && !sameAs.includes(by)) {
          const how = { held: '押したまま', tapped: '一度押し', locked: 'Shiftロック' }[s.how];
          out.push(`${how}の入力は別のルール（${rule ? rule.source : '定義なし'}）が優先されるため、この変更は効きません。`);
        }
      }
    }
    return out;
  }

  /**
   * remap.sh status output as {kcmLoaded, shadowedBy, conflicts, applied, flags, modifiers, touch}.
   * Touch fields: tpSaved and tpLive are "rom", "off" or "gesture" (tpLive also "foreign");
   * tpExcluded is "yes", "no", or "" when dumpsys gave no excluded device list; tpThresholds is
   * [{name, def, min, max, integer}] from touchgestured; tpDaemon is "running", "stopped",
   * "unneeded" (no gesture assigned), "pending" (until the next boot) or "", with tpDaemonLog the
   * last line of its log when it stopped.
   */
  function parseStatus(text) {
    const st = { kcmLoaded: '', klLoaded: '', shadowedBy: [], conflicts: [], applied: false, klApplied: false,
      klEditable: false, flags: [], klBase: {}, klLive: {},
      tpSaved: 'rom', tpLive: 'rom', tpExcluded: '', tpForeign: [], tpConflicts: [],
      tpThresholds: [], tpDaemon: '', tpDaemonLog: '' };
    for (const line of text.split('\n')) {
      const i = line.indexOf('=');
      if (i < 0) continue;
      const [k, v] = [line.slice(0, i), line.slice(i + 1)];
      if (k === 'kcm_loaded') st.kcmLoaded = v;
      else if (k === 'shadowed_by') st.shadowedBy.push(v);
      else if (k === 'conflict_module') st.conflicts.push(v);
      else if (k === 'applied') st.applied = v === 'yes';
      else if (k === 'flag') st.flags.push(v);
      else if (k === 'kl_loaded') st.klLoaded = v;
      else if (k === 'kl_applied') st.klApplied = v === 'yes';
      else if (k === 'kl_editable') st.klEditable = v === 'yes';
      else if (k === 'tp_saved') st.tpSaved = v;
      else if (k === 'tp_live') st.tpLive = v;
      else if (k === 'tp_excluded') st.tpExcluded = v;
      else if (k === 'tp_foreign') st.tpForeign.push(v);
      else if (k === 'tp_conflict_module') st.tpConflicts.push(v);
      else if (k === 'tp_daemon') st.tpDaemon = v;
      else if (k === 'tp_daemon_log') st.tpDaemonLog = v;
      else if (k === 'tp_threshold') {
        const [name, def, min, max, kind] = v.split(':');
        if ([def, min, max].every((x) => x !== undefined && Number.isFinite(Number(x))) && (kind === 'int' || kind === 'real')) {
          st.tpThresholds.push({ name, def: Number(def), min: Number(min), max: Number(max), integer: kind === 'int' });
        }
      }
      else if (k === 'kl_base' || k === 'kl_live') {
        const [scan, code] = v.split(':');
        st[k === 'kl_base' ? 'klBase' : 'klLive'][scan] = code;
      }
    }
    return st;
  }

  /** Diagnostics for remap.sh status (see parseStatus) as [{warn, text}], problems first. */
  function diagnose(st) {
    const out = [];
    if (!st.klLoaded) out.push({ warn: true, text: 'Androidが読み込んだキー配置（stmpe.kl）を確認できません。' });
    else if (!/\/stmpe\.kl$/.test(st.klLoaded)) {
      out.push({ warn: true, text: `Androidは${st.klLoaded}を使っています。stmpe.klを読み込めず、汎用のキー配置に切り替わった可能性があります。` });
    }
    if (!st.kcmLoaded) out.push({ warn: true, text: 'Androidが読み込んだ文字配列（stmpe.kcm）を確認できません。' });
    else if (!/\/stmpe\.kcm$/.test(st.kcmLoaded)) {
      out.push({ warn: true, text: `Androidは${st.kcmLoaded}を使っています。stmpe.kcmを読み込めず、汎用の文字配列に切り替わった可能性があります。` });
    }
    for (const p of st.shadowedBy) out.push({ warn: true, text: `${p}が優先されるため、このモジュールの設定は使われません。` });
    for (const m of st.conflicts) out.push({ warn: true, text: `モジュール${m}もstmpe.kcmかstmpe.klを置き換えています。` });
    if (!st.klEditable) out.push({ warn: true, text: '修飾キーの割り当てを変えるには、モジュールを入れ直してください（元のキー配置が保存されていません）。' });
    if (st.flags.includes('update')) out.push({ warn: true, text: 'モジュールの更新が再起動待ちです。再起動するまで保存できません。' });
    if (st.flags.includes('remove')) out.push({ warn: true, text: 'モジュールの削除が再起動待ちです。' });
    if (st.flags.includes('disable')) out.push({ warn: true, text: 'モジュールは無効です。再起動後は導入前の状態に戻ります。' });
    for (const p of st.tpForeign) out.push({ warn: true, text: `${p}があるため、キーボードのタッチ操作をオフにできません。` });
    for (const m of st.tpConflicts) out.push({ warn: true, text: `モジュール${m}も除外デバイス一覧（excluded-input-devices.xml）を追加しているため、キーボードのタッチ操作をオフにできません。` });
    // Both "off" and "gesture" take the surface from Android with the module's excluded device list.
    const takes = (mode) => mode === 'off' || mode === 'gesture';
    const modeName = (mode) => (mode === 'off' ? 'オフ' : '独自ジェスチャー');
    if (!takes(st.tpSaved) && !takes(st.tpLive) && st.tpExcluded === 'yes') {
      out.push({ warn: true, text: 'このモジュール以外の設定で、キーボードのタッチ操作がオフになっています。' });
    }
    if (takes(st.tpSaved) && st.tpLive === st.tpSaved && st.tpExcluded === 'no') {
      out.push({ warn: true, text: `タッチ操作を${modeName(st.tpSaved)}にする設定は配置されていますが、Androidに使われていません。` });
    }
    if (st.kcmLoaded && /\/stmpe\.kcm$/.test(st.kcmLoaded)) out.push({ warn: false, text: `Androidは${st.kcmLoaded}を読み込んでいます。` });
    if (st.klLoaded && /\/stmpe\.kl$/.test(st.klLoaded)) out.push({ warn: false, text: `Androidは${st.klLoaded}を読み込んでいます。` });
    if (st.tpSaved === 'gesture' && st.tpLive === 'gesture') {
      if (st.tpDaemon === 'stopped') {
        out.push({ warn: true, text: 'ジェスチャーを読み取る常駐プログラムが動いていません。' +
          (st.tpDaemonLog ? `最後の記録：${st.tpDaemonLog}` : '保存し直すか、再起動してください。') });
      } else if (st.tpDaemon === 'pending') {
        out.push({ warn: false, text: '割り当てたジェスチャーは、再起動後に使えます。' });
      } else if (st.tpDaemon === 'unneeded') {
        out.push({ warn: false, text: 'ジェスチャーが割り当てられていないため、常駐プログラムは動かしていません。' });
      }
    }
    const touchApplied = takes(st.tpSaved) ? st.tpLive === st.tpSaved : !takes(st.tpLive);
    if (takes(st.tpSaved)) {
      if (!touchApplied) out.push({ warn: false, text: `キーボードのタッチ操作は再起動後に${modeName(st.tpSaved)}になります。` });
      else if (st.tpExcluded !== 'no') out.push({ warn: false, text: `キーボードのタッチ操作は${modeName(st.tpSaved)}です。` });
    } else if (takes(st.tpLive)) {
      out.push({ warn: false, text: 'キーボードのタッチ操作は再起動後にROMの標準に戻ります。' });
    }
    out.push(st.applied && st.klApplied && touchApplied ? { warn: false, text: '保存した設定は使用中です。' }
      : { warn: false, text: '保存した設定は再起動後に反映されます。' });
    out.push({ warn: false, text: '修飾キーの現在の割り当て：' + Object.keys(PHYSICAL)
      .map((scan) => `${PHYSICAL[scan]}は${roleName(st.klLive[scan] || '')}`).join('、') });
    return out;
  }

  /** The caution shown for every change of a modifier key's role. */
  const ROLE_NOTICE = 'この変更はすべてのレイヤーに効き、キーボード全体の動きが変わります。';

  const MODIFIER_NAMES = { shift: 'Shift', alt: 'Alt', ctrl: 'Ctrl', meta: 'Meta', sym: 'SYM', fn: 'Fn',
    capslock: 'CapsLock', numlock: 'NumLock', scrolllock: 'ScrollLock' };

  /** Display name of a modifier name ("lalt" -> "左Alt"). */
  function modifierLabel(m) {
    if (MODIFIER_NAMES[m]) return MODIFIER_NAMES[m];
    const side = /^([lr])(shift|alt|ctrl|meta)$/.exec(m);
    return side ? (side[1] === 'l' ? '左' : '右') + MODIFIER_NAMES[side[2]] : m;
  }

  /** Display name of a modifier key role (key code label). */
  function roleName(code) { return ROLE_NAMES[code] || (code ? ACTIONS[code] || code : '?'); }

  /** Each physical modifier key's role: BASE (scan -> key code) overridden by "kl:SCAN" in MAP. */
  function rolesOf(base, map) {
    const roles = {};
    for (const scan of Object.keys(PHYSICAL)) roles[scan] = map['kl:' + scan] || base[scan] || '';
    return roles;
  }

  /**
   * Layer an assignment ID is counted and reset under. A modifier key role ("kl:SCAN") is the
   * key's own output, not a modifier combination, so it belongs to the base layer.
   */
  function layerOf(id) { return id.startsWith('kl:') ? 'base' : id.split(':')[0]; }

  /** Pressable modifiers (see availableModifiers) given the physical modifier keys' ROLES. */
  function availableFromRoles(roles) { return availableModifiers(Object.values(roles).filter(Boolean)); }

  /**
   * Cautions for giving physical modifier key SCAN the role CODE: modifiers no longer on any key,
   * and character map assignments in MAP that become unreachable.
   */
  function roleWarnings({ scan, code, base, map }) {
    const out = [ROLE_NOTICE];
    const before = availableFromRoles(rolesOf(base, map));
    const after = availableFromRoles(rolesOf(base, { ...map, ['kl:' + scan]: code }));
    const lost = ['shift', 'alt', 'ctrl', 'meta', 'sym', 'fn'].filter((g) => before.has(g) && !after.has(g));
    if (lost.length) out.push(`${lost.map(modifierLabel).join('、')}を押せるキーがなくなります。`);
    // Gesture keys of a lost modifier's layer are stranded too ("tp:sym_1_tap").
    const lostLayer = (id) => { const m = /^tp:(shift|alt|ctrl|sym)_[123]_/.exec(id); return !!m && lost.includes(m[1]); };
    const stranded = Object.keys(map).filter((id) => (id.startsWith('tp:') ? lostLayer(id) : !id.startsWith('kl:') &&
      unreachableParts(id.split(':')[0], after).length > 0 && unreachableParts(id.split(':')[0], before).length === 0))
      .map((id) => (id.startsWith('tp:') ? gestureName(id) : id));
    if (stranded.length) out.push(`押せなくなるレイヤーに${stranded.length}件の割り当てがあります（${stranded.slice(0, 3).join('、')}${stranded.length > 3 ? 'など' : ''}）。`);
    return out;
  }

  /** Assignments that differ between SAVED and CURRENT maps: [{id, from, to}] sorted by id. */
  function diffAssignments(saved, current) {
    const ids = [...new Set([...Object.keys(saved), ...Object.keys(current)])].sort();
    return ids.filter((id) => saved[id] !== current[id]).map((id) => ({ id, from: saved[id], to: current[id] }));
  }

  /** Palette categories for the assignment panel; together they hold every key code in ACTIONS once. */
  const PALETTE = [
    { id: 'cursor', label: 'カーソル', codes: ['DPAD_LEFT', 'DPAD_DOWN', 'DPAD_UP', 'DPAD_RIGHT', 'MOVE_HOME', 'MOVE_END', 'PAGE_UP', 'PAGE_DOWN', 'DPAD_CENTER'] },
    { id: 'edit', label: '編集', codes: ['TAB', 'ESCAPE', 'ENTER', 'SPACE', 'DEL', 'FORWARD_DEL', 'INSERT'] },
    { id: 'function', label: 'Fキー', codes: Array.from({ length: 12 }, (_, i) => 'F' + (i + 1)) },
    { id: 'alnum', label: '英数字', codes: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.split('') },
    { id: 'symbol', label: '記号キー', codes: ['COMMA', 'PERIOD', 'MINUS', 'EQUALS', 'LEFT_BRACKET', 'RIGHT_BRACKET', 'BACKSLASH', 'SEMICOLON', 'APOSTROPHE', 'SLASH', 'GRAVE', 'AT', 'POUND', 'PLUS', 'STAR'] },
    { id: 'system', label: 'システム', codes: ['BACK', 'HOME', 'MENU', 'SEARCH', 'LANGUAGE_SWITCH', 'SWITCH_CHARSET'] },
  ];

  /** Short key-cap names of key codes for the keyboard legend (letters and digits are themselves). */
  const SHORT = {
    DPAD_LEFT: '←', DPAD_DOWN: '↓', DPAD_UP: '↑', DPAD_RIGHT: '→', DPAD_CENTER: '決定',
    MOVE_HOME: 'Home', MOVE_END: 'End', PAGE_UP: 'PgUp', PAGE_DOWN: 'PgDn',
    TAB: 'Tab', ESCAPE: 'Esc', ENTER: '⏎', SPACE: '␣', DEL: '⌫', FORWARD_DEL: 'Del', INSERT: 'Ins',
    BACK: '戻る', HOME: 'ホーム', MENU: 'Menu', SEARCH: '検索', LANGUAGE_SWITCH: 'IME', SWITCH_CHARSET: '文字種',
    COMMA: ',', PERIOD: '.', MINUS: '-', EQUALS: '=', LEFT_BRACKET: '[', RIGHT_BRACKET: ']', BACKSLASH: '\\',
    SEMICOLON: ';', APOSTROPHE: "'", SLASH: '/', GRAVE: '`', AT: '@', POUND: '#', PLUS: '+', STAR: '*',
  };

  /** Key-cap text for a key code label. */
  function shortName(code) { return SHORT[code] || code; }

  /**
   * Key-cap legend for what a held key does (an evaluate() result): {text, kind} with kind
   * "replace" (another key), "char", "none" (rule without character) or "undefined" (no rule).
   */
  function legend(r) {
    if (!r.rule) return { text: '', kind: 'undefined' };
    if (r.rule.replace) return { text: shortName(r.key), kind: 'replace' };
    if (!r.character) return { text: '—', kind: 'none' };
    const visible = { 0x20: '␣', 0x0a: '⏎', 0x09: '⇥' }[r.character];
    return { text: visible || String.fromCharCode(r.character), kind: 'char' };
  }

  // KeyboardEvent.code values whose Android key code label is not the code itself.
  const CODE_TO_KEY = {
    ArrowLeft: 'DPAD_LEFT', ArrowDown: 'DPAD_DOWN', ArrowUp: 'DPAD_UP', ArrowRight: 'DPAD_RIGHT',
    Home: 'MOVE_HOME', End: 'MOVE_END', PageUp: 'PAGE_UP', PageDown: 'PAGE_DOWN', Insert: 'INSERT',
    Delete: 'FORWARD_DEL', Backspace: 'DEL', Enter: 'ENTER', NumpadEnter: 'ENTER', Space: 'SPACE',
    Tab: 'TAB', Escape: 'ESCAPE', Comma: 'COMMA', Period: 'PERIOD', Minus: 'MINUS', Equal: 'EQUALS',
    BracketLeft: 'LEFT_BRACKET', BracketRight: 'RIGHT_BRACKET', Backslash: 'BACKSLASH',
    Semicolon: 'SEMICOLON', Quote: 'APOSTROPHE', Slash: 'SLASH', Backquote: 'GRAVE',
  };
  const KEY_TO_KEY = { ' ': 'SPACE', ArrowLeft: 'DPAD_LEFT', ArrowDown: 'DPAD_DOWN', ArrowUp: 'DPAD_UP',
    ArrowRight: 'DPAD_RIGHT', Backspace: 'DEL', Delete: 'FORWARD_DEL', Enter: 'ENTER', Tab: 'TAB', Escape: 'ESCAPE',
    Home: 'MOVE_HOME', End: 'MOVE_END', PageUp: 'PAGE_UP', PageDown: 'PAGE_DOWN', Insert: 'INSERT' };

  /** Android key code label for a KeyboardEvent ({code, key}), or null if it has none here. */
  function keyCodeOf(e) {
    let m;
    if (e.code) {
      if (CODE_TO_KEY[e.code]) return CODE_TO_KEY[e.code];
      if ((m = /^Key([A-Z])$/.exec(e.code)) || (m = /^Digit([0-9])$/.exec(e.code)) || (m = /^(F(?:[1-9]|1[0-2]))$/.exec(e.code))) return m[1];
    }
    if (KEY_TO_KEY[e.key]) return KEY_TO_KEY[e.key];
    if (/^[a-zA-Z0-9]$/.test(e.key || '')) return e.key.toUpperCase();
    if (/^F(?:[1-9]|1[0-2])$/.test(e.key || '')) return e.key;
    return null;
  }

  /** The editable KEY2 key a KeyboardEvent came from, or null. The $ key reports the 4 key. */
  function editableKeyOf(e) {
    const code = keyCodeOf(e) || (e.key === '$' ? '4' : null);
    return code && KEYS.includes(code) ? code : null;
  }

  return {
    META, MODIFIERS, ORDER, ROWS, KEYS, ACTIONS,
    canonical, validValue, validId, validate, parseKcm, matchesMetaState, evaluate,
    availableModifiers, unreachableParts, pressStates, companions, ruleLayers, effectiveRows,
    TOUCH_GESTURES, TOUCH_LAYERS, gestureId, gestureName, parseTouchKey, formatTouchKey, touchKeyText, validThreshold,
    warnings, parseStatus, diagnose, diffAssignments, PALETTE, shortName, legend, keyCodeOf, editableKeyOf,
    PHYSICAL, LAYOUT, ROLE_MODIFIERS, ROLE_NOTICE, validRole, roleName, modifierLabel, rolesOf, layerOf, availableFromRoles, roleWarnings,
  };
});
