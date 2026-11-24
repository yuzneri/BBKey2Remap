/*
 * Host-side driver of the touchgestured recogniser, for tests and for replaying device logs.
 *   gesturetool check CONFIG    validate a settings file; prints the effective settings
 */
#include "config.h"

#include <stdio.h>
#include <string.h>

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

int main(int argc, char **argv)
{
    struct tg_config cfg;
    if (argc == 3 && !strcmp(argv[1], "check")) {
        if (load(argv[2], &cfg)) return 1;
        dump(&cfg);
        return 0;
    }
    fprintf(stderr, "usage: gesturetool check CONFIG\n");
    return 2;
}
