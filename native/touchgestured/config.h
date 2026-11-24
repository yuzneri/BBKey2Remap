/* Settings of touchgestured: thresholds, gesture bindings, passthrough and physical modifiers. */
#ifndef TOUCHGESTURED_CONFIG_H
#define TOUCHGESTURED_CONFIG_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#define TG_MAX_FINGERS 3
#define TG_MAX_MODS 16

/* Gestures in the order of tg_gesture_names(); swipes use 4 directions, flicks 8. */
enum tg_gesture {
    TG_SWIPE_UP, TG_SWIPE_DOWN, TG_SWIPE_LEFT, TG_SWIPE_RIGHT,
    TG_FLICK_UP, TG_FLICK_DOWN, TG_FLICK_LEFT, TG_FLICK_RIGHT,
    TG_FLICK_UP_LEFT, TG_FLICK_UP_RIGHT, TG_FLICK_DOWN_LEFT, TG_FLICK_DOWN_RIGHT,
    TG_TAP,
    TG_GESTURE_COUNT
};

enum { TG_MOD_CTRL = 1, TG_MOD_SHIFT = 2, TG_MOD_ALT = 4, TG_MOD_META = 8 };

/* A key to send: a scancode of the virtual keyboard plus TG_MOD_* bits. scancode 0 means unbound. */
struct tg_binding {
    uint16_t scancode;
    uint8_t mods;
};

struct tg_config {
    double start_mm;      /* movement before a touch counts as a swipe */
    double step_mm;       /* movement per key of a continuous swipe */
    double flick_mm_s;    /* speed since the fingers started moving that makes a touch a flick */
    int tap_ms;           /* longest touch that counts as a tap */
    int hold_ms;          /* no key is sent before a touch is this old */
    int gather_ms;        /* fingers landing this soon after the first one join the gesture */
    int after_key_ms;     /* touches starting this soon after a key press are ignored */
    struct tg_binding bind[TG_MAX_FINGERS][TG_GESTURE_COUNT]; /* [fingers - 1][gesture] */
    bool pass[TG_MAX_FINGERS];                                /* [fingers - 1]: hand to the ROM */
    struct { uint16_t scancode; uint8_t mod; } mods[TG_MAX_MODS]; /* physical modifier keys */
    int nmods;
};

/* Fills cfg with the default thresholds and no bindings. */
void tg_config_defaults(struct tg_config *cfg);

/*
 * Reads a whole settings file on top of the defaults. Returns 0, or -1 with "LINE: reason" in err;
 * a file with any bad line is rejected as a whole so the daemon never runs a partial setting.
 */
int tg_config_load(struct tg_config *cfg, FILE *in, char *err, size_t errlen);

/*
 * Writes one line "NAME DEFAULT MIN MAX int|real" per threshold, the defaults, accepted ranges and
 * kinds of number of the settings file, so that the WebUI shows and checks them without a copy.
 */
void tg_config_print_thresholds(FILE *out);

/* "swipe up", "flick down-left", "tap": the settings-file spelling of a gesture. */
const char *tg_gesture_name(enum tg_gesture g);

/* Writes TG_MOD_* bits as "ctrl+shift", or "-" for none, into buf. */
void tg_mods_format(uint8_t mods, char *buf, size_t len);

#endif
