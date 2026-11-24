/*
 * Host-side driver of the touchgestured recogniser, for tests and for replaying device logs.
 *   gesturetool check CONFIG    validate a settings file; prints the effective settings
 *   gesturetool replay CONFIG LOG [--resolution UNITS_PER_MM] [--touch DEVICE]
 *       feed a `getevent -lt` capture to the recogniser and print one line per key:
 *       "MS FINGERS-finger GESTURE key SCANCODE [MODIFIERS]", MS counted from the first event.
 *       Lines with a device prefix are used only when it is DEVICE (default /dev/input/event1).
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
    NAME(BTN_TOOL_QUADTAP), NAME(BTN_TOOL_QUINTTAP),
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
        for (int g = 0; g < TG_GESTURE_COUNT; g++) {
            const struct tg_binding *b = &c->bind[f][g];
            if (!b->scancode) continue;
            char mods[32];
            tg_mods_format(b->mods, mods, sizeof mods);
            printf("bind %d %s key 0x%x%s%s\n", f + 1, tg_gesture_name(g), b->scancode, b->mods ? " " : "", b->mods ? mods : "");
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

/*
 * Parses "[   77941.651292] EV_ABS ABS_MT_POSITION_X 0000030f", optionally with "/dev/input/eventN: "
 * after the timestamp. Returns 1 for an event, 0 for a line to skip, -1 for a malformed event line.
 */
static int parse_line(char *line, const char *touch, struct tg_event *ev)
{
    long sec, usec, type, code, value;
    int n = 0;
    if (sscanf(line, " [ %ld.%6ld]%n", &sec, &usec, &n) != 2 || !n) return 0;
    char *tok[4];
    int ntok = 0;
    for (char *save, *t = strtok_r(line + n, " \t\r\n", &save); t && ntok < 4; t = strtok_r(NULL, " \t\r\n", &save))
        tok[ntok++] = t;
    char **f = tok;
    if (ntok && tok[0][0] == '/') {
        size_t len = strlen(tok[0]);
        if (tok[0][len - 1] == ':') tok[0][len - 1] = '\0';
        if (strcmp(tok[0], touch)) return 0;
        f++;
        ntok--;
    }
    if (ntok != 3 || !LOOKUP(TYPES, f[0], &type) || !LOOKUP(CODES, f[1], &code) ||
        !LOOKUP(VALUES, f[2], &value))
        return -1;
    *ev = (struct tg_event){ .t_us = sec * 1000000 + usec, .type = (uint16_t)type, .code = (uint16_t)code, .value = (int32_t)value };
    return 1;
}

static int replay(const struct tg_config *cfg, const char *path, double resolution, const char *touch)
{
    FILE *in = fopen(path, "r");
    if (!in) { perror(path); return 1; }
    struct tg_state st;
    struct tg_sink sink = { .key = print_key };
    tg_init(&st, cfg, resolution, &sink);
    char line[512];
    int64_t last = 0;
    for (int lineno = 1; fgets(line, sizeof line, in); lineno++) {
        struct tg_event ev;
        int rc = parse_line(line, touch, &ev);
        if (rc < 0) { fprintf(stderr, "%s:%d: not a getevent -lt event line\n", path, lineno); fclose(in); return 1; }
        if (!rc) continue;
        if (origin_us < 0) origin_us = ev.t_us;
        tg_touch_event(&st, &ev);
        last = ev.t_us;
    }
    fclose(in);
    tg_advance(&st, last + 60 * 1000000LL); /* let pending deadlines pass */
    return 0;
}

int main(int argc, char **argv)
{
    struct tg_config cfg;
    if (argc == 3 && !strcmp(argv[1], "check")) {
        if (load(argv[2], &cfg)) return 1;
        dump(&cfg);
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "replay")) {
        double resolution = 21;
        const char *touch = "/dev/input/event1";
        for (int i = 4; i < argc; i += 2) {
            if (i + 1 == argc) goto usage;
            if (!strcmp(argv[i], "--resolution")) resolution = atof(argv[i + 1]);
            else if (!strcmp(argv[i], "--touch")) touch = argv[i + 1];
            else goto usage;
        }
        if (resolution <= 0 || load(argv[2], &cfg)) return 1;
        return replay(&cfg, argv[3], resolution, touch);
    }
usage:
    fprintf(stderr, "usage: gesturetool check CONFIG\n"
                    "       gesturetool replay CONFIG LOG [--resolution UNITS_PER_MM] [--touch DEVICE]\n");
    return 2;
}
