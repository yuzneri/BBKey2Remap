/* Gesture recogniser of touchgestured; the rules are in the design notes of PR2 (2026-11-24). */
#include "gesture.h"

#include <linux/input-event-codes.h>
#include <string.h>

#define MS(v) ((int64_t)(v) * 1000)

void tg_init(struct tg_state *st, const struct tg_config *cfg, double units_per_mm, const struct tg_sink *sink)
{
    memset(st, 0, sizeof *st);
    st->cfg = *cfg;
    st->sink = *sink;
    st->units_per_mm = units_per_mm;
}

static bool any_bound(const struct tg_state *st, int fingers, int first, int last)
{
    for (int g = first; g <= last; g++)
        if (st->cfg.bind[fingers - 1][g].scancode) return true;
    return false;
}

static void emit(struct tg_state *st, enum tg_gesture g)
{
    const struct tg_binding *b = &st->cfg.bind[st->fingers - 1][g];
    if (b->scancode) st->sink.key(st->sink.ctx, st->now, st->fingers, g, b);
}

static double start_units(const struct tg_state *st) { return st->cfg.start_mm * st->units_per_mm; }

/* The fingers down when the gathering time ends are the gesture's fingers; later ones are ignored. */
static void count_fingers(struct tg_state *st)
{
    st->fingers = st->max_active;
    if (st->fingers > TG_MAX_FINGERS || !any_bound(st, st->fingers, 0, TG_GESTURE_COUNT - 1)) {
        st->phase = TG_DONE;
        return;
    }
    for (int s = 0; s < TG_SLOTS; s++) st->c[s].counted = st->c[s].active;
    st->phase = TG_TRACK;
}

/* A counted finger was lifted: the gesture ends now and the remaining fingers are ignored. */
static void finish(struct tg_state *st)
{
    int64_t held = st->now - st->t0;
    st->phase = TG_DONE;
    if (held < MS(st->cfg.hold_ms)) return;
    double start = start_units(st);
    if (held <= MS(st->cfg.tap_ms) && st->max_d2 < start * start) emit(st, TG_TAP);
}

static void begin_touch(struct tg_state *st, int active)
{
    st->phase = TG_GATHER;
    st->t0 = st->now;
    st->ax = st->ay = 0;
    st->max_d2 = 0;
    st->max_active = active;
    st->fingers = 0;
}

/* Adds the mean movement, since the previous frame, of the fingers that are in both frames. */
static void accumulate(struct tg_state *st)
{
    double dx = 0, dy = 0;
    int n = 0;
    for (int s = 0; s < TG_SLOTS; s++) {
        struct tg_contact *c = &st->c[s];
        bool tracked = c->active && c->has_pos && (st->phase == TG_GATHER || c->counted);
        if (tracked && c->in_prev) {
            dx += c->x - c->px;
            dy += c->y - c->py;
            n++;
        }
        c->in_prev = tracked;
        c->px = c->x;
        c->py = c->y;
    }
    if (n) {
        st->ax += dx / n;
        st->ay += dy / n;
    }
    double d2 = st->ax * st->ax + st->ay * st->ay;
    if (d2 > st->max_d2) st->max_d2 = d2;
}

static void end_frame(struct tg_state *st)
{
    int active = 0;
    for (int s = 0; s < TG_SLOTS; s++) active += st->c[s].active && st->c[s].has_pos;

    if (st->phase == TG_IDLE && active) begin_touch(st, active);
    if (st->phase != TG_IDLE) accumulate(st);

    if (st->phase == TG_GATHER) {
        if (active > st->max_active) st->max_active = active;
        if (st->lifted_in_frame) {
            count_fingers(st);
            if (st->phase == TG_TRACK) finish(st);
        }
    } else if (st->phase == TG_TRACK && st->counted_lifted) {
        finish(st);
    }
    st->lifted_in_frame = st->counted_lifted = false;

    if (!active) {
        st->phase = TG_IDLE;
        for (int s = 0; s < TG_SLOTS; s++) st->c[s].counted = false;
    }
    tg_advance(st, st->now); /* a zero gathering time ends on the first frame */
}

void tg_touch_event(struct tg_state *st, const struct tg_event *ev)
{
    tg_advance(st, ev->t_us);
    struct tg_contact *c = st->slot >= 0 ? &st->c[st->slot] : NULL;
    if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
        end_frame(st);
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_SLOT) {
        st->slot = ev->value >= 0 && ev->value < TG_SLOTS ? ev->value : -1;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_TRACKING_ID && c) {
        /* A new id without a -1 first also ends the old contact. */
        if (c->active) st->lifted_in_frame = true;
        if (c->active && c->counted) st->counted_lifted = true;
        c->active = ev->value >= 0;
        c->counted = false;
        if (c->active) c->has_pos = c->in_prev = false;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_POSITION_X && c) {
        c->x = ev->value;
        c->has_pos = true;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_POSITION_Y && c) {
        c->y = ev->value;
    }
}

int64_t tg_next_deadline(const struct tg_state *st)
{
    if (st->phase == TG_GATHER) return st->t0 + MS(st->cfg.gather_ms);
    return INT64_MAX;
}

void tg_advance(struct tg_state *st, int64_t now_us)
{
    for (int64_t d; (d = tg_next_deadline(st)) <= now_us;) {
        if (d > st->now) st->now = d;
        if (st->phase == TG_GATHER) count_fingers(st);
    }
    if (now_us > st->now) st->now = now_us;
}
