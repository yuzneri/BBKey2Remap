/*
 * Host-side driver of the touchgestured recogniser, for tests and for replaying device logs.
 *   gesturetool check CONFIG    validate a settings file; prints the effective settings
 *   gesturetool thresholds      the thresholds' defaults and ranges, as touchgestured prints them
 *   gesturetool replay CONFIG LOG [--resolution UNITS_PER_MM] [--touch DEVICE] [--keys DEVICE]
 *       feed a `getevent -lt` capture to the recogniser and print one line per key:
 *       "MS FINGERS-finger GESTURE key SCANCODE [MODIFIERS]", MS counted from the first event.
 *       Lines without a device prefix are touch events. Prefixed lines are touch events when the
 *       prefix is the --touch DEVICE (default /dev/input/event1), keyboard events when it is the
 *       --keys DEVICE (default /dev/input/event2), and skipped otherwise.
 *       Events passed through to the virtual touchpad print as "MS pass TYPE CODE VALUE" with
 *       their original time and getevent's names and hexadecimal values.
 *       Two pseudo events stand for what the daemon reads from the kernel: "RESYNC CURRENT_SLOT
 *       ID:X:Y|-1 ..." on the touch surface (tg_resync) and "HELD SCANCODE ..." on the keyboard
 *       (tg_set_held_keys).
 */
#include "config.h"
#include "gesture.h"

#include <ctype.h>
#include <linux/input-event-codes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NAME(x) { #x, x }
static const struct name { const char *name; int value; } TYPES[] = {
    NAME(EV_SYN), NAME(EV_KEY), NAME(EV_REL), NAME(EV_ABS), NAME(EV_MSC), NAME(EV_SW),
}, CODES[] = {
    NAME(SYN_REPORT), NAME(SYN_CONFIG), NAME(SYN_MT_REPORT), NAME(SYN_DROPPED),
    NAME(ABS_X), NAME(ABS_Y), NAME(ABS_PRESSURE),
    NAME(ABS_MT_SLOT), NAME(ABS_MT_TOUCH_MAJOR), NAME(ABS_MT_TOUCH_MINOR), NAME(ABS_MT_WIDTH_MAJOR),
    NAME(ABS_MT_WIDTH_MINOR), NAME(ABS_MT_ORIENTATION), NAME(ABS_MT_POSITION_X), NAME(ABS_MT_POSITION_Y),
    NAME(ABS_MT_TOOL_TYPE), NAME(ABS_MT_TRACKING_ID), NAME(ABS_MT_PRESSURE), NAME(ABS_MT_DISTANCE),
    NAME(BTN_TOUCH), NAME(BTN_TOOL_FINGER), NAME(BTN_TOOL_DOUBLETAP), NAME(BTN_TOOL_TRIPLETAP),
    NAME(BTN_TOOL_QUADTAP), NAME(BTN_TOOL_QUINTTAP), NAME(MSC_SCAN),
}, KEYS[] = {
#include "keynames.inc"
}, VALUES[] = { { "UP", 0 }, { "DOWN", 1 }, { "REPEAT", 2 } };

/* Looks NAME up in a table, or reads it as the hexadecimal number getevent prints otherwise. */
static bool lookup(const struct name *t, size_t n, const char *s, long *out)
{
    for (size_t i = 0; i < n; i++)
        if (!strcmp(t[i].name, s)) { *out = t[i].value; return true; }
    char *end;
    if (!isxdigit((unsigned char)*s)) return false;
    unsigned long v = strtoul(s, &end, 16);
    if (*end) return false;
    *out = (long)(int32_t)(uint32_t)v; /* ffffffff is -1 */
    return true;
}
#define LOOKUP(t, s, out) lookup(t, sizeof t / sizeof *t, s, out)

static int load(const char *path, struct tg_config *cfg)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return -1; }
    char err[256];
    int rc = tg_config_load(cfg, f, err, sizeof err);
    fclose(f);
    if (rc) fprintf(stderr, "%s:%s\n", path, err);
    return rc;
}

/* Prints every setting, defaults included, in the settings-file syntax. */
static void dump(const struct tg_config *c)
{
    printf("start_mm %g\nstep_mm %g\nflick_mm_s %g\n", c->start_mm, c->step_mm, c->flick_mm_s);
    printf("tap_ms %d\nhold_ms %d\ngather_ms %d\nafter_key_ms %d\n", c->tap_ms, c->hold_ms, c->gather_ms, c->after_key_ms);
    for (int f = 0; f < TG_MAX_FINGERS; f++) {
        if (c->pass[f]) printf("pass %d\n", f + 1);
        for (int l = 0; l < TG_LAYER_COUNT; l++)
            for (int g = 0; g < TG_GESTURE_COUNT; g++) {
                const struct tg_binding *b = &c->bind[l][f][g];
                if (!tg_bound(b)) continue;
                if (b->scroll) {
                    printf("bind %s%s%d %s scroll\n", tg_layer_name(l), l ? " " : "", f + 1, tg_gesture_name(g));
                    continue;
                }
                char mods[32];
                tg_mods_format(b->mods, mods, sizeof mods);
                printf("bind %s%s%d %s key 0x%x%s%s%s\n", tg_layer_name(l), l ? " " : "", f + 1, tg_gesture_name(g),
                       b->scancode, b->mods ? " " : "", b->mods ? mods : "", b->once ? " once" : "");
            }
    }
    for (int i = 0; i < c->nmods; i++) {
        char mod[32];
        tg_mods_format(c->mods[i].mod, mod, sizeof mod);
        printf("mod %d %s\n", c->mods[i].scancode, mod);
    }
}

static int64_t origin_us = -1;

static void print_key(void *ctx, int64_t t_us, int fingers, enum tg_gesture g, const struct tg_binding *b)
{
    (void)ctx;
    char mods[32];
    tg_mods_format(b->mods, mods, sizeof mods);
    printf("%lld %d-finger %s key 0x%x%s%s\n", (long long)((t_us - origin_us) / 1000), fingers,
           tg_gesture_name(g), b->scancode, b->mods ? " " : "", b->mods ? mods : "");
}

/* The name of value in table t among the names starting with prefix, or "?". */
static const char *name_of(const struct name *t, size_t n, const char *prefix, int value)
{
    for (size_t i = 0; i < n; i++)
        if (t[i].value == value && !strncmp(t[i].name, prefix, strlen(prefix))) return t[i].name;
    return "?";
}
#define NAME_OF(t, prefix, v) name_of(t, sizeof t / sizeof *t, prefix, v)

static void print_pass(void *ctx, const struct tg_event *ev)
{
    (void)ctx;
    const char *prefix = ev->type == EV_SYN ? "SYN_" : ev->type == EV_ABS ? "ABS_" : ev->type == EV_KEY ? "BTN_" : "";
    printf("%lld pass %s %s ", (long long)((ev->t_us - origin_us) / 1000), NAME_OF(TYPES, "EV_", ev->type),
           NAME_OF(CODES, prefix, ev->code));
    if (ev->type == EV_KEY) printf("%s\n", NAME_OF(VALUES, "", ev->value));
    else printf("%08x\n", (uint32_t)ev->value);
}

enum source { SKIP, FROM_TOUCH, FROM_KEYS };

#define MAX_WORDS (2 + TG_SLOTS)

/* A log line: its time, which device it is from, and its words after any device prefix. */
struct line {
    enum source src;
    int64_t t_us;
    char *word[MAX_WORDS];
    int nwords;
};

/*
 * Splits "[   77941.651292] EV_ABS ABS_MT_POSITION_X 0000030f", optionally with "/dev/input/eventN: "
 * after the timestamp. Returns false for a line that is not from the touch surface or keyboard.
 */
static bool split_line(char *text, const char *touch, const char *keys, struct line *l)
{
    long sec, usec;
    int n = 0;
    if (sscanf(text, " [ %ld.%6ld]%n", &sec, &usec, &n) != 2 || !n) return false;
    l->src = FROM_TOUCH;
    l->t_us = sec * 1000000 + usec;
    l->nwords = 0;
    char *save, *w = strtok_r(text + n, " \t\r\n", &save);
    if (w && w[0] == '/') {
        size_t len = strlen(w);
        if (w[len - 1] == ':') w[len - 1] = '\0';
        if (!strcmp(w, keys)) l->src = FROM_KEYS;
        else if (strcmp(w, touch)) return false;
        w = strtok_r(NULL, " \t\r\n", &save);
    }
    for (; w; w = strtok_r(NULL, " \t\r\n", &save)) {
        if (l->nwords == MAX_WORDS) { l->nwords = -1; break; }
        l->word[l->nwords++] = w;
    }
    return true;
}

static bool parse_event(const struct line *l, struct tg_event *ev)
{
    long type, code, value;
    if (l->nwords != 3 || !LOOKUP(TYPES, l->word[0], &type) ||
        !(LOOKUP(CODES, l->word[1], &code) || LOOKUP(KEYS, l->word[1], &code)) || !LOOKUP(VALUES, l->word[2], &value))
        return false;
    *ev = (struct tg_event){ .t_us = l->t_us, .type = (uint16_t)type, .code = (uint16_t)code, .value = (int32_t)value };
    return true;
}

/* "RESYNC CURRENT_SLOT ID:X:Y|-1 ...": what the daemon reads from the kernel after SYN_DROPPED. */
static bool parse_resync(const struct line *l, struct tg_state *st)
{
    int32_t ids[TG_SLOTS], xs[TG_SLOTS], ys[TG_SLOTS];
    int current, nslots = l->nwords - 2;
    char end;
    if (nslots < 1 || sscanf(l->word[1], "%d%c", &current, &end) != 1) return false;
    for (int s = 0; s < nslots; s++) {
        xs[s] = ys[s] = 0;
        int got = sscanf(l->word[2 + s], "%d:%d:%d%c", &ids[s], &xs[s], &ys[s], &end);
        if (!(got == 3 || (got == 1 && ids[s] == -1))) return false;
    }
    tg_resync(st, l->t_us, nslots, ids, xs, ys, current);
    return true;
}

/* "HELD SCANCODE ...": the keys the daemon reads as held when it (re)opens the keyboard. */
static bool parse_held(const struct line *l, struct tg_state *st)
{
    uint8_t bits[KEY_CNT / 8 + 1] = { 0 };
    for (int i = 1; i < l->nwords; i++) {
        char *end;
        long code = strtol(l->word[i], &end, 10);
        if (*end || code < 0 || code >= KEY_CNT) return false;
        bits[code / 8] |= (uint8_t)(1 << (code % 8));
    }
    tg_set_held_keys(st, bits, sizeof bits);
    return true;
}

static int replay(const struct tg_config *cfg, const char *path, double resolution, const char *touch, const char *keys)
{
    FILE *in = fopen(path, "r");
    if (!in) { perror(path); return 1; }
    struct tg_state st;
    struct tg_sink sink = { .key = print_key, .pass = print_pass };
    tg_init(&st, cfg, resolution, &sink);
    char text[512];
    int64_t last = 0;
    for (int lineno = 1; fgets(text, sizeof text, in); lineno++) {
        struct line l;
        if (!split_line(text, touch, keys, &l)) continue;
        if (origin_us < 0) origin_us = l.t_us;
        struct tg_event ev;
        bool ok = l.nwords > 0;
        if (ok && !strcmp(l.word[0], "RESYNC")) ok = l.src == FROM_TOUCH && parse_resync(&l, &st);
        else if (ok && !strcmp(l.word[0], "HELD")) ok = l.src == FROM_KEYS && parse_held(&l, &st);
        else if (ok && (ok = parse_event(&l, &ev))) {
            if (l.src == FROM_KEYS) tg_key_event(&st, &ev);
            else tg_touch_event(&st, &ev);
        }
        if (!ok) { fprintf(stderr, "%s:%d: not a getevent -lt event line\n", path, lineno); fclose(in); return 1; }
        last = l.t_us;
    }
    fclose(in);
    tg_advance(&st, last + 60 * 1000000LL); /* let pending deadlines pass */
    return 0;
}

int main(int argc, char **argv)
{
    struct tg_config cfg;
    if (argc == 2 && !strcmp(argv[1], "thresholds")) {
        tg_config_print_thresholds(stdout);
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "check")) {
        if (load(argv[2], &cfg)) return 1;
        dump(&cfg);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "replay")) {
        double resolution = 21;
        const char *touch = "/dev/input/event1", *keys = "/dev/input/event2";
        for (int i = 4; i < argc; i += 2) {
            if (i + 1 == argc) goto usage;
            if (!strcmp(argv[i], "--resolution")) resolution = atof(argv[i + 1]);
            else if (!strcmp(argv[i], "--touch")) touch = argv[i + 1];
            else if (!strcmp(argv[i], "--keys")) keys = argv[i + 1];
            else goto usage;
        }
        if (resolution <= 0 || load(argv[2], &cfg)) return 1;
        return replay(&cfg, argv[3], resolution, touch, keys);
    }
usage:
    fprintf(stderr, "usage: gesturetool check CONFIG\n"
                    "       gesturetool thresholds\n"
                    "       gesturetool replay CONFIG LOG [--resolution UNITS_PER_MM] [--touch DEVICE] [--keys DEVICE]\n");
    return 2;
}
