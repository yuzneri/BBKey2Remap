/* Parser of the touchgestured settings file (written by remap.sh). */
#include "config.h"

#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LINE 256
#define MAX_SCANCODE 0x2ff /* KEY_MAX */

static const char *const GESTURE_NAMES[TG_GESTURE_COUNT] = {
    "swipe up", "swipe down", "swipe left", "swipe right",
    "flick up", "flick down", "flick left", "flick right",
    "tap",
};

/* In TG_MOD_* bit order. */
static const char *const MOD_NAMES[] = { "ctrl", "shift", "alt", "meta", "sym" };
#define MOD_COUNT 5

static const char *const LAYER_NAMES[TG_LAYER_COUNT] = { "", "shift", "alt", "ctrl", "sym" };
static const uint8_t LAYER_MODS[TG_LAYER_COUNT] = { 0, TG_MOD_SHIFT, TG_MOD_ALT, TG_MOD_CTRL, TG_MOD_SYM };

const char *tg_gesture_name(enum tg_gesture g) { return GESTURE_NAMES[g]; }
const char *tg_layer_name(enum tg_layer l) { return LAYER_NAMES[l]; }
uint8_t tg_layer_mod(enum tg_layer l) { return LAYER_MODS[l]; }

void tg_config_defaults(struct tg_config *cfg)
{
    memset(cfg, 0, sizeof *cfg);
    cfg->start_mm = 2;
    cfg->step_mm = 3;
    cfg->flick_mm_s = 60;
    cfg->tap_ms = 200;
    cfg->hold_ms = 0;
    cfg->gather_ms = 150;
    cfg->after_key_ms = 300;
}

void tg_mods_format(uint8_t mods, char *buf, size_t len)
{
    size_t used = 0;
    buf[0] = '\0';
    for (int i = 0; i < MOD_COUNT; i++) {
        if (!(mods & (1 << i))) continue;
        used += (size_t)snprintf(buf + used, used < len ? len - used : 0, "%s%s", used ? "+" : "", MOD_NAMES[i]);
    }
    if (!used) snprintf(buf, len, "-");
}

struct parser {
    struct tg_config *cfg;
    unsigned seen;   /* bit per threshold, to reject repeats */
    char *err;
    size_t errlen;
    int line;
};

static int fail(struct parser *p, const char *fmt, ...)
{
    int n = snprintf(p->err, p->errlen, "%d: ", p->line);
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(p->err + n, n < (int)p->errlen ? p->errlen - (size_t)n : 0, fmt, ap);
    va_end(ap);
    return -1;
}

static bool parse_number(const char *s, double lo, double hi, double *out)
{
    char *end;
    double v = strtod(s, &end);
    if (end == s || *end || !isfinite(v) || v < lo || v > hi) return false;
    *out = v;
    return true;
}

/* Decimal or 0x-prefixed hexadecimal, as KL files accept. */
static bool parse_code(const char *s, long hi, long *out)
{
    char *end;
    if (*s == '-' || *s == '+') return false;
    long v = strtol(s, &end, 0);
    if (end == s || *end || v < 1 || v > hi) return false;
    *out = v;
    return true;
}

/* A passthrough finger count goes to the ROM before any gesture of it could be recognised. */
static int pass_conflict(struct parser *p, int fingers)
{
    return fail(p, "%d-finger gestures are both passed through and bound", fingers);
}

static int parse_fingers(struct parser *p, const char *s)
{
    if (s && s[0] >= '1' && s[0] <= '0' + TG_MAX_FINGERS && !s[1]) return s[0] - '0';
    return fail(p, "finger count must be 1-%d", TG_MAX_FINGERS);
}

/* Modifier names joined by "+" into TG_MOD_* bits, accepting only the ones in ALLOWED. */
static int parse_mods(const char *s, uint8_t allowed, uint8_t *out)
{
    uint8_t mods = 0;
    char buf[MAX_LINE];
    snprintf(buf, sizeof buf, "%s", s);
    for (char *save, *tok = strtok_r(buf, "+", &save); tok; tok = strtok_r(NULL, "+", &save)) {
        int i = 0;
        while (i < MOD_COUNT && strcmp(tok, MOD_NAMES[i])) i++;
        if (i == MOD_COUNT || !(allowed & (1 << i)) || (mods & (1 << i))) return -1;
        mods |= (uint8_t)(1 << i);
    }
    if (!mods || s[0] == '+' || s[strlen(s) - 1] == '+' || strstr(s, "++")) return -1;
    *out = mods;
    return 0;
}

static const struct threshold {
    const char *name;
    double lo, hi;
    bool integer;
    size_t offset;
} THRESHOLDS[] = {
    { "start_mm", 0.5, 25, false, offsetof(struct tg_config, start_mm) },
    { "step_mm", 0.5, 25, false, offsetof(struct tg_config, step_mm) },
    { "flick_mm_s", 10, 5000, false, offsetof(struct tg_config, flick_mm_s) },
    { "tap_ms", 0, 2000, true, offsetof(struct tg_config, tap_ms) },
    { "hold_ms", 0, 2000, true, offsetof(struct tg_config, hold_ms) },
    { "gather_ms", 0, 500, true, offsetof(struct tg_config, gather_ms) },
    { "after_key_ms", 0, 5000, true, offsetof(struct tg_config, after_key_ms) },
};

static int parse_threshold(struct parser *p, int i, char **tok, int ntok)
{
    const struct threshold *t = &THRESHOLDS[i];
    double v;
    if (ntok != 2) return fail(p, "%s takes one value", t->name);
    if (p->seen & (1u << i)) return fail(p, "%s is set twice", t->name);
    if (!parse_number(tok[1], t->lo, t->hi, &v) || (t->integer && v != floor(v)))
        return fail(p, "%s must be %s from %g to %g", t->name, t->integer ? "a whole number" : "a number", t->lo, t->hi);
    p->seen |= 1u << i;
    char *field = (char *)p->cfg + t->offset;
    if (t->integer) *(int *)field = (int)v;
    else *(double *)field = v;
    return 0;
}

/*
 * bind [LAYER] FINGERS swipe DIRECTION key SCANCODE [MODS] [once]
 * bind [LAYER] FINGERS swipe DIRECTION scroll
 * bind [LAYER] FINGERS flick DIRECTION key SCANCODE [MODS]
 * bind [LAYER] FINGERS tap key SCANCODE [MODS]
 */
static int parse_bind(struct parser *p, char **tok, int ntok)
{
    int layer = TG_LAYER_BASE;
    for (int l = TG_LAYER_SHIFT; ntok > 1 && l < TG_LAYER_COUNT; l++)
        if (!strcmp(tok[1], LAYER_NAMES[l])) layer = l;
    if (layer != TG_LAYER_BASE) {
        tok++;
        ntok--;
    }
    int fingers = parse_fingers(p, ntok > 1 ? tok[1] : NULL);
    if (fingers < 0) return -1;
    if (ntok < 3) return fail(p, "bind needs a gesture");
    char name[MAX_LINE];
    int at = 3;
    if (!strcmp(tok[2], "tap")) snprintf(name, sizeof name, "tap");
    else if (ntok > 3) snprintf(name, sizeof name, "%s %s", tok[2], tok[at++]);
    else return fail(p, "%s needs a direction", tok[2]);
    int g = 0;
    while (g < TG_GESTURE_COUNT && strcmp(name, GESTURE_NAMES[g])) g++;
    if (g == TG_GESTURE_COUNT) return fail(p, "unknown gesture \"%s\"", name);
    struct tg_binding *b = &p->cfg->bind[layer][fingers - 1][g];
    if (tg_bound(b)) return fail(p, "%s%s%d-finger %s is bound twice", LAYER_NAMES[layer], layer ? " " : "", fingers, name);
    if (p->cfg->pass[fingers - 1]) return pass_conflict(p, fingers);
    if (ntok - at == 1 && !strcmp(tok[at], "scroll")) {
        if (g > TG_SWIPE_RIGHT) return fail(p, "scroll is only for swipes");
        b->scroll = true;
        return 0;
    }
    bool once = ntok - at >= 3 && !strcmp(tok[ntok - 1], "once");
    if (once) ntok--;
    if (ntok - at < 2 || ntok - at > 3 || strcmp(tok[at], "key"))
        return fail(p, "bind ends with key SCANCODE [MODIFIERS] [once], or scroll");
    if (once && g > TG_SWIPE_RIGHT) return fail(p, "once is only for swipes, which repeat");
    long code;
    if (!parse_code(tok[at + 1], MAX_SCANCODE, &code)) return fail(p, "scancode must be 1-0x%x", MAX_SCANCODE);
    uint8_t mods = 0;
    if (ntok - at == 3 && parse_mods(tok[at + 2], TG_MOD_CTRL | TG_MOD_SHIFT | TG_MOD_ALT | TG_MOD_META, &mods))
        return fail(p, "modifiers must be ctrl, shift, alt and meta joined by +");
    b->scancode = (uint16_t)code;
    b->mods = mods;
    b->once = once;
    return 0;
}

static int parse_mod(struct parser *p, char **tok, int ntok)
{
    struct tg_config *c = p->cfg;
    long code;
    uint8_t mod;
    if (ntok != 3) return fail(p, "mod takes a scancode and a modifier");
    if (!parse_code(tok[1], MAX_SCANCODE, &code)) return fail(p, "scancode must be 1-0x%x", MAX_SCANCODE);
    if (parse_mods(tok[2], 0xff, &mod) || (mod & (mod - 1))) return fail(p, "modifier must be ctrl, shift, alt, meta or sym");
    for (int i = 0; i < c->nmods; i++)
        if (c->mods[i].scancode == code) return fail(p, "scancode %ld has two modifiers", code);
    if (c->nmods == TG_MAX_MODS) return fail(p, "more than %d modifier keys", TG_MAX_MODS);
    c->mods[c->nmods].scancode = (uint16_t)code;
    c->mods[c->nmods++].mod = mod;
    return 0;
}

static int parse_line(struct parser *p, char *line)
{
    line += strspn(line, " \t");
    if (*line == '#') return 0;
    char *tok[10];
    int ntok = 0;
    for (char *save, *t = strtok_r(line, " \t", &save); t; t = strtok_r(NULL, " \t", &save)) {
        if (ntok == 10) return fail(p, "too many words");
        tok[ntok++] = t;
    }
    if (!ntok) return 0;
    for (size_t i = 0; i < sizeof THRESHOLDS / sizeof *THRESHOLDS; i++)
        if (!strcmp(tok[0], THRESHOLDS[i].name)) return parse_threshold(p, (int)i, tok, ntok);
    if (!strcmp(tok[0], "bind")) return parse_bind(p, tok, ntok);
    if (!strcmp(tok[0], "mod")) return parse_mod(p, tok, ntok);
    if (!strcmp(tok[0], "pass")) {
        int fingers = parse_fingers(p, ntok == 2 ? tok[1] : NULL);
        if (fingers < 0) return -1;
        if (p->cfg->pass[fingers - 1]) return fail(p, "pass %d is set twice", fingers);
        for (int l = 0; l < TG_LAYER_COUNT; l++)
            for (int g = 0; g < TG_GESTURE_COUNT; g++)
                if (tg_bound(&p->cfg->bind[l][fingers - 1][g])) return pass_conflict(p, fingers);
        p->cfg->pass[fingers - 1] = true;
        return 0;
    }
    return fail(p, "unknown setting \"%s\"", tok[0]);
}

bool tg_config_passes(const struct tg_config *c)
{
    for (int f = 0; f < TG_MAX_FINGERS; f++) {
        if (c->pass[f]) return true;
        for (int l = 0; l < TG_LAYER_COUNT; l++)
            for (int g = TG_SWIPE_UP; g <= TG_SWIPE_RIGHT; g++)
                if (c->bind[l][f][g].scroll) return true;
    }
    return false;
}

void tg_config_print_thresholds(FILE *out)
{
    struct tg_config cfg;
    tg_config_defaults(&cfg);
    for (size_t i = 0; i < sizeof THRESHOLDS / sizeof *THRESHOLDS; i++) {
        const struct threshold *t = &THRESHOLDS[i];
        const char *field = (const char *)&cfg + t->offset;
        double value = t->integer ? *(const int *)field : *(const double *)field;
        fprintf(out, "%s %g %g %g %s\n", t->name, value, t->lo, t->hi, t->integer ? "int" : "real");
    }
}

int tg_config_load(struct tg_config *cfg, FILE *in, char *err, size_t errlen)
{
    struct parser p = { .cfg = cfg, .err = err, .errlen = errlen };
    char line[MAX_LINE + 2];
    tg_config_defaults(cfg);
    while (fgets(line, sizeof line, in)) {
        p.line++;
        size_t n = strlen(line);
        if (n && line[n - 1] == '\n') line[--n] = '\0';
        else if (!feof(in)) return fail(&p, "line is longer than %d bytes", MAX_LINE);
        if (parse_line(&p, line)) return -1;
    }
    if (ferror(in)) return fail(&p, "read error");
    return 0;
}
