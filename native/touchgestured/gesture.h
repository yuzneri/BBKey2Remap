/*
 * Gesture recogniser of touchgestured: turns the multi-touch (protocol B) events of touch_keypad
 * into gesture keys. It does no I/O; the caller feeds events and time and receives keys through
 * a sink, so the same code runs in the daemon and in host tests.
 */
#ifndef TOUCHGESTURED_GESTURE_H
#define TOUCHGESTURED_GESTURE_H

#include "config.h"

#include <stdbool.h>
#include <stdint.h>

#define TG_SLOTS 16
#define TG_HISTORY 32
/* Events kept until the finger count is known: 500 ms of 3 fingers at 120 Hz is about 800. */
#define TG_PASS_BUFFER 1024

/* One evdev event; t_us is the event timestamp in microseconds. */
struct tg_event {
    int64_t t_us;
    uint16_t type, code;
    int32_t value;
};

struct tg_sink {
    void *ctx;
    /* A recognised gesture with a binding; called once per key to send. */
    void (*key)(void *ctx, int64_t t_us, int fingers, enum tg_gesture g, const struct tg_binding *b);
    /* An event for the virtual touchpad of a passed-through touch; t_us is its original time. */
    void (*pass)(void *ctx, const struct tg_event *ev);
};

struct tg_contact {
    bool active, has_pos, counted, in_prev;
    int32_t x, y, px, py; /* current and previous-frame position */
};

enum tg_phase { TG_IDLE, TG_GATHER, TG_TRACK, TG_PASS, TG_DONE };

struct tg_state {
    struct tg_config cfg;
    struct tg_sink sink;
    double units_per_mm;
    struct tg_contact c[TG_SLOTS];
    int slot;
    bool lifted_in_frame, counted_lifted; /* since the last SYN_REPORT */
    /* the current touch: from the first finger landing until every finger is lifted */
    enum tg_phase phase;
    int64_t t0, now;
    int fingers, max_active;
    double ax, ay;   /* accumulated movement of the counted fingers, device units */
    double max_d2;   /* largest squared distance from the starting point so far */
    struct { int64_t t; double x, y; } hist[TG_HISTORY]; /* (ax, ay) per frame, a ring */
    int hist_len, hist_next;
    /* continuous swipe */
    bool swiping, committed; /* committed: swipe keys were sent, so it can no longer be a flick */
    int axis;                /* 0: X, 1: Y */
    double anchor;           /* position on the axis where the last step was counted */
    int pending;             /* steps counted but held back while the touch may be a flick */
    /* events since the touch started, replayed if it is passed through */
    struct tg_event buf[TG_PASS_BUFFER];
    int buf_len, buf_slot;   /* buf_slot: the slot in effect before the first buffered event */
    bool buf_overflow;
    bool dropping;           /* after SYN_DROPPED, until the next SYN_REPORT */
};

/* Starts with no fingers down. units_per_mm is the resolution of the X and Y axes. */
void tg_init(struct tg_state *st, const struct tg_config *cfg, double units_per_mm, const struct tg_sink *sink);

/*
 * Feeds one event of touch_keypad; time is first advanced to the event's timestamp. SYN_DROPPED
 * abandons the current touch; the caller should then feed the device's current slot state.
 */
void tg_touch_event(struct tg_state *st, const struct tg_event *ev);

/* Moves time forward to now_us, acting on any deadline that has passed. */
void tg_advance(struct tg_state *st, int64_t now_us);

/* The next time tg_advance must be called even if no event arrives, or INT64_MAX. */
int64_t tg_next_deadline(const struct tg_state *st);

#endif
