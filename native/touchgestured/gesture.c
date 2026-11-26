/* Gesture recogniser of touchgestured; the rules are in the design notes of PR2 (2026-11-24). */
#include "gesture.h"

#include <linux/input-event-codes.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define MS(v) ((int64_t)(v) * 1000)
/* A moving finger reports a frame about every 8 ms; one silent this long has stopped. */
#define STILL_US MS(50)

void tg_init(struct tg_state *st, const struct tg_config *cfg, double units_per_mm, const struct tg_sink *sink)
{
    memset(st, 0, sizeof *st);
    st->cfg = *cfg;
    st->sink = *sink;
    st->units_per_mm = units_per_mm;
    st->last_key_us = INT64_MIN / 2;
}

/* A finger on the surface that can take part in a gesture. */
static bool usable(const struct tg_contact *c) { return c->active && c->has_pos && !c->on_key; }

/* TG_MOD_* bits of the physical modifiers held. */
static uint8_t held_mods(const struct tg_state *st)
{
    uint8_t mods = 0;
    for (int i = 0; i < st->cfg.nmods; i++)
        if (st->mods_down & (1u << i)) mods |= st->cfg.mods[i].mod;
    return mods;
}

/*
 * The layer whose binding gesture G of FINGERS uses: the first layer, in tg_layer order, whose
 * modifier was held during the touch and that binds it, otherwise the base layer. A modifier let go
 * just before the finger still counts, as it naturally is when ending a gesture.
 */
static enum tg_layer layer_of(const struct tg_state *st, int fingers, enum tg_gesture g)
{
    uint8_t held = st->layer_mods | held_mods(st);
    for (int l = TG_LAYER_SHIFT; l < TG_LAYER_COUNT; l++)
        if ((held & tg_layer_mod(l)) && tg_bound(&st->cfg.bind[l][fingers - 1][g])) return l;
    return TG_LAYER_BASE;
}

static const struct tg_binding *binding(const struct tg_state *st, int fingers, enum tg_gesture g)
{
    return &st->cfg.bind[layer_of(st, fingers, g)][fingers - 1][g];
}

static bool any_bound(const struct tg_state *st, int fingers, int first, int last)
{
    for (int g = first; g <= last; g++)
        if (tg_bound(binding(st, fingers, g))) return true;
    return false;
}

/*
 * Sends the gesture's key if it has one; returns whether it did. The physical modifiers held are
 * added, except the one whose layer the key comes from, and SYM, which has no key to send.
 */
static bool emit(struct tg_state *st, enum tg_gesture g)
{
    enum tg_layer l = layer_of(st, st->fingers, g);
    struct tg_binding b = st->cfg.bind[l][st->fingers - 1][g];
    if (!b.scancode) return false;
    b.mods |= held_mods(st) & ~tg_layer_mod(l) & ~TG_MOD_SYM;
    st->sink.key(st->sink.ctx, st->now, st->fingers, g, &b);
    return true;
}

static double start_units(const struct tg_state *st) { return st->cfg.start_mm * st->units_per_mm; }

static bool swipes_bound(const struct tg_state *st) { return any_bound(st, st->fingers, TG_SWIPE_UP, TG_SWIPE_RIGHT); }
static bool flicks_bound(const struct tg_state *st) { return any_bound(st, st->fingers, TG_FLICK_UP, TG_FLICK_RIGHT); }

/*
 * Speed in mm/s since the fingers started to move (left half of start_mm behind): the distance over
 * that time. In flicks and swipes recorded on the device, the speed just before the lift does not
 * tell them apart (the finger slows while it leaves the surface), and neither does the speed from
 * the landing, since a flick may rest a while before it starts. This one does, already when the
 * swipe would start: 60 mm/s splits all 11 recorded flicks from all 8 swipes.
 */
static double speed(const struct tg_state *st)
{
    int64_t moving = st->now - st->t_move;
    if (moving <= 0) return 0;
    return hypot(st->ax, st->ay) / st->units_per_mm / ((double)moving / 1e6);
}

static bool may_be_flick(const struct tg_state *st)
{
    return !st->committed && flicks_bound(st) && speed(st) >= st->cfg.flick_mm_s;
}

static void start_passthrough(struct tg_state *st);

/* The swipe the counted steps go in. */
static enum tg_gesture pending_swipe(const struct tg_state *st)
{
    return st->axis ? (st->pending < 0 ? TG_SWIPE_UP : TG_SWIPE_DOWN) : (st->pending < 0 ? TG_SWIPE_LEFT : TG_SWIPE_RIGHT);
}

static void send_pending(struct tg_state *st)
{
    enum tg_gesture g = pending_swipe(st);
    /* A scroll hands the whole touch to the ROM, unless keys were sent already: those and the
     * ROM's scrolling of the same movement would both happen, so then it does nothing. */
    if (binding(st, st->fingers, g)->scroll) {
        st->pending = 0;
        if (!st->committed) start_passthrough(st);
        return;
    }
    /* Steps in a direction without a key send nothing, so the touch may still become a flick. */
    int n = abs(st->pending);
    if (binding(st, st->fingers, g)->once) {
        if (st->sent_once[g]) n = 0;
        else if (n) n = 1, st->sent_once[g] = true;
    }
    for (; n > 0; n--) st->committed |= emit(st, g);
    st->pending = 0;
}

/*
 * Continuous swipe: starts once the touch is hold_ms old and has moved start_mm along an axis that
 * has a binding, which sends the first key. The axis is then fixed, and each further step_mm along
 * it sends another key, in the opposite direction when the finger goes back. A scroll does not
 * wait to see whether the touch is a flick: the ROM scrolls a flick on as it would its own.
 */
static void track(struct tg_state *st)
{
    if (!swipes_bound(st) || st->now - st->t0 < MS(st->cfg.hold_ms)) return;
    double start = start_units(st), step = st->cfg.step_mm * st->units_per_mm;
    if (!st->swiping) {
        double cx = any_bound(st, st->fingers, TG_SWIPE_LEFT, TG_SWIPE_RIGHT) ? fabs(st->ax) : -1;
        double cy = any_bound(st, st->fingers, TG_SWIPE_UP, TG_SWIPE_DOWN) ? fabs(st->ay) : -1;
        if (cx < start && cy < start) return;
        st->swiping = true;
        st->axis = cy > cx;
        double pos = st->axis ? st->ay : st->ax;
        st->pending = pos < 0 ? -1 : 1;
        st->anchor = copysign(start, pos);
    }
    double pos = st->axis ? st->ay : st->ax;
    for (; pos - st->anchor >= step; st->anchor += step) st->pending++;
    for (; pos - st->anchor <= -step; st->anchor -= step) st->pending--;
    if (st->pending && (!may_be_flick(st) || binding(st, st->fingers, pending_swipe(st))->scroll)) send_pending(st);
}

/* The larger axis of the movement since the touch started (Y grows downwards), horizontal on a tie. */
static enum tg_gesture flick_direction(double ax, double ay)
{
    if (fabs(ax) >= fabs(ay)) return ax < 0 ? TG_FLICK_LEFT : TG_FLICK_RIGHT;
    return ay < 0 ? TG_FLICK_UP : TG_FLICK_DOWN;
}

/* Whether a gesture with more than n fingers has anything to do; if not, there is no need to wait. */
static bool more_fingers_used(const struct tg_state *st, int n)
{
    for (int f = n + 1; f <= TG_MAX_FINGERS; f++)
        if (st->cfg.pass[f - 1] || any_bound(st, f, 0, TG_GESTURE_COUNT - 1)) return true;
    return false;
}

/* The fingers down when the gathering time ends are the gesture's fingers; later ones are ignored. */
static void pass(struct tg_state *st, int64_t t_us, uint16_t type, uint16_t code, int32_t value)
{
    struct tg_event ev = { .t_us = t_us, .type = type, .code = code, .value = value };
    st->sink.pass(st->sink.ctx, &ev);
}

/*
 * Hands the touch to the ROM from its start, without the fingers on keys. Protocol B leaves out
 * ABS_MT_SLOT when the slot has not changed, so the replay begins by selecting the slot the device
 * was on, which the virtual touchpad cannot otherwise know. Likewise BTN_TOUCH goes down only with
 * the first finger on the surface: when that was a finger on a key, which is not passed, the
 * virtual touchpad would take the passed fingers as hovering, so the replay presses it first.
 */
static void start_passthrough(struct tg_state *st)
{
    if (st->buf_overflow) {
        st->phase = TG_DONE;
        return;
    }
    st->phase = TG_PASS;
    for (int s = 0; s < TG_SLOTS; s++) st->c[s].passed = st->c[s].active && !st->c[s].on_key;
    int64_t t = st->buf[0].t_us;
    pass(st, t, EV_ABS, ABS_MT_SLOT, st->buf_slot);
    bool touching = false;
    for (int i = 0; i < st->buf_len; i++) touching = touching || (st->buf[i].type == EV_KEY && st->buf[i].code == BTN_TOUCH);
    if (!touching) {
        pass(st, t, EV_KEY, BTN_TOUCH, 1);
        pass(st, t, EV_KEY, BTN_TOOL_FINGER, 1);
    }
    for (int i = 0; i < st->buf_len; i++) st->sink.pass(st->sink.ctx, &st->buf[i]);
    st->buf_len = 0;
}

static void count_fingers(struct tg_state *st)
{
    st->fingers = st->max_active;
    if (st->fingers <= TG_MAX_FINGERS && st->cfg.pass[st->fingers - 1]) {
        start_passthrough(st);
        return;
    }
    if (st->fingers > TG_MAX_FINGERS || !any_bound(st, st->fingers, 0, TG_GESTURE_COUNT - 1)) {
        st->phase = TG_DONE;
        return;
    }
    for (int s = 0; s < TG_SLOTS; s++) st->c[s].counted = usable(&st->c[s]);
    st->phase = TG_TRACK;
}

/* A counted finger was lifted: the gesture ends now and the remaining fingers are ignored. */
static void finish(struct tg_state *st)
{
    int64_t held = st->now - st->t0;
    st->phase = TG_DONE;
    if (held < MS(st->cfg.hold_ms) || st->committed) return;
    double start = start_units(st);
    if (st->ax * st->ax + st->ay * st->ay >= start * start && may_be_flick(st)) {
        enum tg_gesture g = flick_direction(st->ax, st->ay);
        /* Swipes and flicks list their directions in the same order. */
        if (binding(st, st->fingers, TG_SWIPE_UP + (g - TG_FLICK_UP))->scroll) {
            start_passthrough(st);
            return;
        }
        if (emit(st, g)) return;
    }
    if (st->pending) send_pending(st);
    else if (held <= MS(st->cfg.tap_ms) && st->max_d2 < start * start) emit(st, TG_TAP);
}

static void begin_touch(struct tg_state *st, int active)
{
    st->phase = TG_GATHER;
    st->t0 = st->now;
    st->ax = st->ay = 0;
    st->max_d2 = 0;
    st->t_move = st->now;
    st->layer_mods = held_mods(st);
    st->max_active = active;
    st->fingers = 0;
    st->swiping = st->committed = false;
    st->pending = 0;
    memset(st->sent_once, 0, sizeof st->sent_once);
    if (st->now - st->last_key_us < MS(st->cfg.after_key_ms)) st->phase = TG_DONE;
}

/* Adds the mean movement, since the previous frame, of the fingers that are in both frames. */
static void accumulate(struct tg_state *st)
{
    double dx = 0, dy = 0;
    int n = 0;
    for (int s = 0; s < TG_SLOTS; s++) {
        struct tg_contact *c = &st->c[s];
        bool tracked = usable(c) && (st->phase == TG_GATHER || c->counted);
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
    double onset = start_units(st) / 2;
    if (d2 < onset * onset) st->t_move = st->now;
    st->t_frame = st->now;
}

/*
 * Whether the current touch's events are still kept for a passthrough: until the fingers are
 * counted for pass, and then until a key is sent for scroll. Kept for every touch, since which
 * binding a swipe takes also depends on the modifiers held when it starts.
 */
static bool keeping(const struct tg_state *st)
{
    return st->phase == TG_GATHER || (st->phase == TG_TRACK && !st->committed);
}

static void release_passthrough(struct tg_state *st, int64_t t_us);

static void end_frame(struct tg_state *st)
{
    int active = 0;
    for (int s = 0; s < TG_SLOTS; s++) active += usable(&st->c[s]);

    if (st->phase == TG_IDLE && active) begin_touch(st, active);
    if (st->phase != TG_IDLE) accumulate(st);

    if (st->phase == TG_GATHER) {
        if (active > st->max_active) st->max_active = active;
        if (st->lifted_in_frame) {
            count_fingers(st);
            if (st->phase == TG_TRACK) track(st);
            if (st->phase == TG_TRACK) finish(st);
        } else if (!more_fingers_used(st, st->max_active)) {
            count_fingers(st);
            if (st->phase == TG_TRACK) track(st);
        }
    } else if (st->phase == TG_TRACK) {
        if (st->counted_lifted) finish(st);
        else track(st);
    }
    st->lifted_in_frame = st->counted_lifted = false;

    /*
     * A passed-through touch belongs to the ROM until its fingers are lifted, also those that went
     * onto a key meanwhile (Shift while scrolling is the ROM's to handle). A finger already on a key
     * when it started is not part of it, so the touch ends without that finger, which the next
     * touch then also leaves out, as it does outside a passthrough.
     */
    bool ended = !active;
    if (st->phase == TG_PASS) {
        bool others = false;
        ended = true;
        for (int s = 0; s < TG_SLOTS; s++) {
            if (!st->c[s].active) continue;
            if (st->c[s].passed) ended = false;
            else others = true;
        }
        if (ended && others) release_passthrough(st, st->now);
    }
    if (ended) {
        st->phase = TG_IDLE;
        for (int s = 0; s < TG_SLOTS; s++) st->c[s].counted = false;
    }
    if (!keeping(st)) {
        st->buf_len = 0;
        st->buf_overflow = false;
    }
    tg_advance(st, st->now); /* a zero gathering time ends on the first frame */
}

/* Ends a passed-through touch on the virtual touchpad: lifts every finger it was given. */
static void release_passthrough(struct tg_state *st, int64_t t_us)
{
    for (int s = 0; s < TG_SLOTS; s++) {
        if (!st->c[s].active) continue;
        pass(st, t_us, EV_ABS, ABS_MT_SLOT, s);
        pass(st, t_us, EV_ABS, ABS_MT_TRACKING_ID, -1);
    }
    static const uint16_t BUTTONS[] = { BTN_TOUCH, BTN_TOOL_FINGER, BTN_TOOL_DOUBLETAP, BTN_TOOL_TRIPLETAP, BTN_TOOL_QUADTAP };
    for (size_t i = 0; i < sizeof BUTTONS / sizeof *BUTTONS; i++) pass(st, t_us, EV_KEY, BUTTONS[i], 0);
    pass(st, t_us, EV_SYN, SYN_REPORT, 0);
}

void tg_touch_event(struct tg_state *st, const struct tg_event *ev)
{
    tg_advance(st, ev->t_us);
    if (ev->type == EV_SYN && ev->code == SYN_DROPPED) {
        if (st->phase == TG_PASS) release_passthrough(st, ev->t_us);
        if (st->phase != TG_IDLE) st->phase = TG_DONE;
        st->buf_len = 0;
        st->dropping = true;
        return;
    }
    if (st->dropping) {
        st->dropping = !(ev->type == EV_SYN && ev->code == SYN_REPORT);
        return;
    }
    if (st->phase == TG_PASS) {
        st->sink.pass(st->sink.ctx, ev);
    } else if (st->phase == TG_IDLE || keeping(st)) {
        if (!st->buf_len) st->buf_slot = st->slot;
        if (st->buf_len < TG_PASS_BUFFER) st->buf[st->buf_len++] = *ev;
        else st->buf_overflow = true;
    }
    struct tg_contact *c = st->slot >= 0 ? &st->c[st->slot] : NULL;
    if (ev->type == EV_SYN && ev->code == SYN_REPORT) {
        end_frame(st);
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_SLOT) {
        st->slot = ev->value >= 0 && ev->value < TG_SLOTS ? ev->value : -1;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_TRACKING_ID && c) {
        /* A new id without a -1 first also ends the old contact. */
        if (c->active && !c->on_key) st->lifted_in_frame = true;
        if (c->active && c->counted) st->counted_lifted = true;
        c->active = ev->value >= 0;
        /* A finger landing on a passed-through touch was handed to the ROM with it. */
        c->passed = st->phase == TG_PASS && c->active;
        c->counted = c->on_key = false;
        /* The kernel keeps a slot's position for the next contact and leaves out an axis whose
         * value did not change, so the old position stays valid. */
        if (c->active) c->in_prev = false;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_POSITION_X && c) {
        c->x = ev->value;
        c->has_pos = true;
    } else if (ev->type == EV_ABS && ev->code == ABS_MT_POSITION_Y && c) {
        c->y = ev->value;
    }
}

/* The index of scancode in cfg.mods, or -1 for a key that is not a modifier. */
static int modifier_index(const struct tg_state *st, int scancode)
{
    for (int i = 0; i < st->cfg.nmods; i++)
        if (st->cfg.mods[i].scancode == scancode) return i;
    return -1;
}

void tg_key_event(struct tg_state *st, const struct tg_event *ev)
{
    tg_advance(st, ev->t_us);
    if (ev->type != EV_KEY) return;
    int mod = modifier_index(st, ev->code);
    if (mod >= 0 && ev->value == 1) {
        st->mods_down |= 1u << mod;
        st->layer_mods |= st->cfg.mods[mod].mod;
    }
    if (mod >= 0 && ev->value == 0) st->mods_down &= ~(1u << mod);
    if (ev->value != 1) return; /* releases and autorepeat change nothing else */
    bool modifier = mod >= 0;
    for (int s = 0; s < TG_SLOTS; s++)
        if (st->c[s].active) st->c[s].on_key = true;
    if (st->phase == TG_PASS) {
        /* The ROM has the touch; a typed key ends it there, a held modifier is left to the ROM. */
        if (modifier) return;
        release_passthrough(st, ev->t_us);
    }
    if (st->phase == TG_GATHER || st->phase == TG_TRACK || st->phase == TG_PASS) {
        /* Nothing sent yet under a modifier means the touch was its finger: start over without it,
         * and without its events, which a passthrough of the next touch must not replay. */
        st->phase = modifier && !st->committed ? TG_IDLE : TG_DONE;
        st->buf_len = 0;
        st->buf_overflow = false;
    }
    if (!modifier) st->last_key_us = ev->t_us;
}

void tg_resync(struct tg_state *st, int64_t t_us, int nslots, const int32_t *ids, const int32_t *xs,
               const int32_t *ys, int current_slot)
{
    struct tg_event ev = { .t_us = t_us, .type = EV_ABS };
    struct tg_event syn = { .t_us = t_us, .type = EV_SYN, .code = SYN_REPORT };
    /* Whatever the touch was, it continued unseen: abandon it, as for SYN_DROPPED. Fingers that
     * are down now stay ignored until lifted, since where they started is unknown. */
    if (st->phase == TG_PASS) release_passthrough(st, t_us);
    st->phase = TG_DONE;
    st->buf_len = 0;
    st->dropping = false;
    for (int s = 0; s < nslots && s < TG_SLOTS; s++) {
        ev.code = ABS_MT_SLOT, ev.value = s;
        tg_touch_event(st, &ev);
        ev.code = ABS_MT_TRACKING_ID, ev.value = ids[s];
        tg_touch_event(st, &ev);
        if (ids[s] < 0) continue;
        ev.code = ABS_MT_POSITION_X, ev.value = xs[s];
        tg_touch_event(st, &ev);
        ev.code = ABS_MT_POSITION_Y, ev.value = ys[s];
        tg_touch_event(st, &ev);
    }
    ev.code = ABS_MT_SLOT, ev.value = current_slot;
    tg_touch_event(st, &ev);
    tg_touch_event(st, &syn);
}

void tg_set_held_keys(struct tg_state *st, const uint8_t *bits, size_t nbytes)
{
    st->mods_down = 0;
    for (int i = 0; bits && i < st->cfg.nmods; i++) {
        size_t code = st->cfg.mods[i].scancode;
        if (code / 8 < nbytes && (bits[code / 8] >> (code % 8)) & 1) st->mods_down |= 1u << i;
    }
}

void tg_set_config(struct tg_state *st, int64_t t_us, const struct tg_config *cfg)
{
    tg_advance(st, t_us);
    /* Part of the touch was measured with the old thresholds and bindings, so neither fits it.
     * While idle, the buffer holds only the first frame of a touch, which is not measured yet. */
    if (st->phase == TG_PASS) release_passthrough(st, t_us);
    if (st->phase != TG_IDLE) {
        st->phase = TG_DONE;
        st->buf_len = 0;
        st->buf_overflow = false;
    }
    /* mods_down is indexed by the position in cfg.mods, which the new list may order differently. */
    uint32_t held = 0;
    for (int i = 0; i < cfg->nmods; i++)
        for (int j = 0; j < st->cfg.nmods; j++)
            if ((st->mods_down >> j & 1) && st->cfg.mods[j].scancode == cfg->mods[i].scancode) held |= 1u << i;
    st->mods_down = held;
    st->cfg = *cfg;
}

int64_t tg_next_deadline(const struct tg_state *st)
{
    if (st->phase == TG_GATHER) return st->t0 + MS(st->cfg.gather_ms);
    if (st->phase != TG_TRACK || !swipes_bound(st)) return INT64_MAX;
    /* A finger held still past hold_ms may already have moved far enough to start a swipe. */
    if (!st->swiping && st->now < st->t0 + MS(st->cfg.hold_ms)) return st->t0 + MS(st->cfg.hold_ms);
    /* Held-back steps are sent once the speed has fallen, which a still finger never reports. The
     * finger counts as still only after STILL_US without frames, since the speed taken between two
     * frames of a moving finger would be too low; without further movement it then falls below
     * flick_mm_s at the second time at the latest. */
    if (st->pending) {
        double mm = hypot(st->ax, st->ay) / st->units_per_mm;
        int64_t slow = st->t_move + (int64_t)(mm / st->cfg.flick_mm_s * 1e6) + 1;
        return st->t_frame + STILL_US > slow ? st->t_frame + STILL_US : slow;
    }
    return INT64_MAX;
}

void tg_advance(struct tg_state *st, int64_t now_us)
{
    for (int64_t d; (d = tg_next_deadline(st)) <= now_us;) {
        if (d > st->now) st->now = d;
        if (st->phase == TG_GATHER) count_fingers(st);
        if (st->phase == TG_TRACK) track(st);
    }
    if (now_us > st->now) st->now = now_us;
}
