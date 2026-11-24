/*
 * touchgestured: recognises gestures on the KEY2 keyboard surface and sends them as keys.
 *   touchgestured CONFIG [--touch NAME] [--keys NAME]
 * It reads the touch surface (default "touch_keypad", which Android must ignore through
 * excluded-input-devices.xml) and the keyboard (default "stmpe_keypad") without grabbing them,
 * and writes to two uinput devices: a keyboard for gesture keys and, when a finger count is passed
 * through, a touchpad with the same axes as the surface for the ROM's own handling.
 */
#include "config.h"
#include "gesture.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define KEYBOARD_NAME "key2remap_touch_keys"
#define TOUCHPAD_NAME "key2remap_touch_pad"
#define RETRY_MS 2000
#define BITS_LONG (8 * sizeof(long))
#define TEST_BIT(bits, n) (((bits)[(n) / BITS_LONG] >> ((n) % BITS_LONG)) & 1)

static const uint16_t MOD_KEYS[4] = { KEY_LEFTCTRL, KEY_LEFTSHIFT, KEY_LEFTALT, KEY_LEFTMETA };

static volatile sig_atomic_t stopping;

struct daemon {
    struct tg_config cfg;
    struct tg_state st;
    const char *touch_name, *keys_name;
    int touch_fd, keys_fd, kbd_fd, pad_fd;
    bool passes;             /* some finger count is passed through to the virtual touchpad */
    bool resync_after_frame; /* SYN_DROPPED seen: reread the slots after the device's next SYN_REPORT */
};

static void on_signal(int sig) { (void)sig; stopping = 1; }

static int64_t now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* Opens the evdev device whose name is exactly name, or returns -1. */
static int open_by_name(const char *name)
{
    DIR *dir = opendir("/dev/input");
    if (!dir) return -1;
    int found = -1;
    for (struct dirent *e; found < 0 && (e = readdir(dir));) {
        if (strncmp(e->d_name, "event", 5)) continue;
        char path[sizeof "/dev/input/" + sizeof e->d_name], got[256] = "";
        snprintf(path, sizeof path, "/dev/input/%s", e->d_name);
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) continue;
        if (ioctl(fd, EVIOCGNAME(sizeof got - 1), got) >= 0 && !strcmp(got, name)) {
            /* Deadlines are kept on CLOCK_MONOTONIC, so the event times must use it too. */
            int clk = CLOCK_MONOTONIC;
            if (ioctl(fd, EVIOCSCLOCKID, &clk) == 0) {
                found = fd;
                fprintf(stderr, "touchgestured: %s is %s\n", name, path);
                continue;
            }
            fprintf(stderr, "touchgestured: %s: EVIOCSCLOCKID: %s\n", path, strerror(errno));
        }
        close(fd);
    }
    closedir(dir);
    return found;
}

static void emit_event(int fd, uint16_t type, uint16_t code, int32_t value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof ev);
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev)
        fprintf(stderr, "touchgestured: uinput write: %s\n", strerror(errno));
}

static int create_device(int fd, const struct input_id *id, const char *name)
{
    struct uinput_setup setup;
    memset(&setup, 0, sizeof setup);
    setup.id = *id;
    snprintf(setup.name, sizeof setup.name, "%s", name);
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "touchgestured: creating %s: %s\n", name, strerror(errno));
        return -1;
    }
    return 0;
}

/*
 * The gesture keyboard has only the bound scancodes and the four left modifiers, so Android does
 * not take it for a full keyboard. Vendor and product stay 0 so the key layout is found by name.
 */
static int create_keyboard(const struct tg_config *cfg)
{
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { fprintf(stderr, "touchgestured: /dev/uinput: %s\n", strerror(errno)); return -1; }
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (int i = 0; i < 4; i++) ioctl(fd, UI_SET_KEYBIT, MOD_KEYS[i]);
    for (int f = 0; f < TG_MAX_FINGERS; f++)
        for (int g = 0; g < TG_GESTURE_COUNT; g++)
            if (cfg->bind[f][g].scancode) ioctl(fd, UI_SET_KEYBIT, cfg->bind[f][g].scancode);
    struct input_id id = { .bustype = BUS_VIRTUAL };
    if (create_device(fd, &id, KEYBOARD_NAME)) { close(fd); return -1; }
    return fd;
}

/* A touchpad copying the surface's properties, buttons and axes, so the ROM treats it the same. */
static int create_touchpad(int src)
{
    unsigned long props[INPUT_PROP_CNT / BITS_LONG + 1] = { 0 }, keys[KEY_CNT / BITS_LONG + 1] = { 0 },
                  abs[ABS_CNT / BITS_LONG + 1] = { 0 };
    struct input_id id;
    if (ioctl(src, EVIOCGID, &id) < 0 || ioctl(src, EVIOCGPROP(sizeof props), props) < 0 ||
        ioctl(src, EVIOCGBIT(EV_KEY, sizeof keys), keys) < 0 || ioctl(src, EVIOCGBIT(EV_ABS, sizeof abs), abs) < 0) {
        fprintf(stderr, "touchgestured: reading the surface's capabilities: %s\n", strerror(errno));
        return -1;
    }
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { fprintf(stderr, "touchgestured: /dev/uinput: %s\n", strerror(errno)); return -1; }
    for (int p = 0; p < INPUT_PROP_CNT; p++)
        if (TEST_BIT(props, p)) ioctl(fd, UI_SET_PROPBIT, p);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    for (int k = 0; k < KEY_CNT; k++)
        if (TEST_BIT(keys, k)) ioctl(fd, UI_SET_KEYBIT, k);
    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    for (int a = 0; a < ABS_CNT; a++) {
        if (!TEST_BIT(abs, a)) continue;
        struct uinput_abs_setup setup = { .code = (uint16_t)a };
        if (ioctl(src, EVIOCGABS(a), &setup.absinfo) < 0 || ioctl(fd, UI_ABS_SETUP, &setup) < 0) {
            fprintf(stderr, "touchgestured: copying axis %d: %s\n", a, strerror(errno));
            close(fd);
            return -1;
        }
    }
    /* Not the surface's own ids: an IDC or KL meant for touch_keypad must not match this device. */
    id.vendor = id.product = 0;
    if (create_device(fd, &id, TOUCHPAD_NAME)) { close(fd); return -1; }
    return fd;
}

static void destroy_device(int *fd)
{
    if (*fd < 0) return;
    ioctl(*fd, UI_DEV_DESTROY);
    close(*fd);
    *fd = -1;
}

static void send_key(void *ctx, int64_t t_us, int fingers, enum tg_gesture g, const struct tg_binding *b)
{
    (void)t_us; (void)fingers; (void)g;
    struct daemon *d = ctx;
    for (int i = 0; i < 4; i++)
        if (b->mods & (1 << i)) emit_event(d->kbd_fd, EV_KEY, MOD_KEYS[i], 1);
    emit_event(d->kbd_fd, EV_SYN, SYN_REPORT, 0);
    emit_event(d->kbd_fd, EV_KEY, b->scancode, 1);
    emit_event(d->kbd_fd, EV_SYN, SYN_REPORT, 0);
    emit_event(d->kbd_fd, EV_KEY, b->scancode, 0);
    emit_event(d->kbd_fd, EV_SYN, SYN_REPORT, 0);
    for (int i = 0; i < 4; i++)
        if (b->mods & (1 << i)) emit_event(d->kbd_fd, EV_KEY, MOD_KEYS[i], 0);
    emit_event(d->kbd_fd, EV_SYN, SYN_REPORT, 0);
}

/* uinput stamps events when they are written, so a replayed touch arrives with fresh times. */
static void pass_event(void *ctx, const struct tg_event *ev)
{
    struct daemon *d = ctx;
    if (d->pad_fd >= 0) emit_event(d->pad_fd, ev->type, ev->code, ev->value);
}

static void feed_touch(struct daemon *d, uint16_t type, uint16_t code, int32_t value)
{
    struct tg_event ev = { .t_us = now_us(), .type = type, .code = code, .value = value };
    tg_touch_event(&d->st, &ev);
}

/*
 * Tells the recogniser the surface's current fingers, read from the kernel: at start, after
 * SYN_DROPPED and after reopening. The leading SYN_REPORT ends the recogniser's dropped state.
 */
static void resync(struct daemon *d)
{
    struct input_absinfo slot_info;
    if (ioctl(d->touch_fd, EVIOCGABS(ABS_MT_SLOT), &slot_info) < 0) {
        fprintf(stderr, "touchgestured: reading the current slot: %s\n", strerror(errno));
        return;
    }
    int slots = slot_info.maximum + 1 < TG_SLOTS ? slot_info.maximum + 1 : TG_SLOTS;
    struct { uint32_t code; int32_t values[TG_SLOTS]; } id = { ABS_MT_TRACKING_ID, { 0 } },
        x = { ABS_MT_POSITION_X, { 0 } }, y = { ABS_MT_POSITION_Y, { 0 } };
    size_t len = sizeof(uint32_t) + sizeof(int32_t) * (size_t)slots;
    if (ioctl(d->touch_fd, EVIOCGMTSLOTS(len), &id) < 0 || ioctl(d->touch_fd, EVIOCGMTSLOTS(len), &x) < 0 ||
        ioctl(d->touch_fd, EVIOCGMTSLOTS(len), &y) < 0) {
        fprintf(stderr, "touchgestured: reading the slots: %s\n", strerror(errno));
        return;
    }
    feed_touch(d, EV_SYN, SYN_REPORT, 0);
    for (int s = 0; s < slots; s++) {
        feed_touch(d, EV_ABS, ABS_MT_SLOT, s);
        feed_touch(d, EV_ABS, ABS_MT_TRACKING_ID, id.values[s]);
        if (id.values[s] < 0) continue;
        feed_touch(d, EV_ABS, ABS_MT_POSITION_X, x.values[s]);
        feed_touch(d, EV_ABS, ABS_MT_POSITION_Y, y.values[s]);
    }
    feed_touch(d, EV_ABS, ABS_MT_SLOT, slot_info.value);
    feed_touch(d, EV_SYN, SYN_REPORT, 0);
}

static int open_touch(struct daemon *d)
{
    d->touch_fd = open_by_name(d->touch_name);
    if (d->touch_fd < 0) return -1;
    struct input_absinfo x;
    if (ioctl(d->touch_fd, EVIOCGABS(ABS_MT_POSITION_X), &x) < 0 || x.resolution <= 0) {
        fprintf(stderr, "touchgestured: %s reports no X resolution\n", d->touch_name);
        close(d->touch_fd);
        d->touch_fd = -1;
        return -1;
    }
    if (d->passes && d->pad_fd < 0 && (d->pad_fd = create_touchpad(d->touch_fd)) < 0) {
        close(d->touch_fd);
        d->touch_fd = -1;
        return -1;
    }
    struct tg_sink sink = { .ctx = d, .key = send_key, .pass = pass_event };
    tg_init(&d->st, &d->cfg, x.resolution, &sink);
    resync(d);
    return 0;
}

/* Drops a device that failed to read; the main loop reopens it. */
static void lose(struct daemon *d, int *fd, const char *name)
{
    fprintf(stderr, "touchgestured: lost %s: %s\n", name, strerror(errno));
    close(*fd);
    *fd = -1;
    if (fd == &d->touch_fd) {
        struct tg_event drop = { .t_us = now_us(), .type = EV_SYN, .code = SYN_DROPPED };
        tg_touch_event(&d->st, &drop);
    }
}

static void read_events(struct daemon *d, int *fd, const char *name)
{
    struct input_event evs[64];
    for (;;) {
        ssize_t n = read(*fd, evs, sizeof evs);
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) return;
        if (n <= 0) { lose(d, fd, name); return; }
        for (size_t i = 0; i < (size_t)n / sizeof *evs; i++) {
            struct tg_event ev = {
                .t_us = (int64_t)evs[i].input_event_sec * 1000000 + evs[i].input_event_usec,
                .type = evs[i].type, .code = evs[i].code, .value = evs[i].value,
            };
            if (fd == &d->keys_fd) {
                tg_key_event(&d->st, &ev);
                continue;
            }
            tg_touch_event(&d->st, &ev);
            if (ev.type == EV_SYN && ev.code == SYN_DROPPED) d->resync_after_frame = true;
            else if (ev.type == EV_SYN && ev.code == SYN_REPORT && d->resync_after_frame) {
                d->resync_after_frame = false;
                resync(d);
            }
        }
    }
}

static int load_config(const char *path, struct tg_config *cfg)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "touchgestured: %s: %s\n", path, strerror(errno)); return -1; }
    char err[256];
    int rc = tg_config_load(cfg, f, err, sizeof err);
    fclose(f);
    if (rc) fprintf(stderr, "touchgestured: %s:%s\n", path, err);
    return rc;
}

int main(int argc, char **argv)
{
    struct daemon d = { .touch_name = "touch_keypad", .keys_name = "stmpe_keypad",
                        .touch_fd = -1, .keys_fd = -1, .kbd_fd = -1, .pad_fd = -1 };
    if (argc < 2 || argc % 2) goto usage;
    for (int i = 2; i < argc; i += 2) {
        if (!strcmp(argv[i], "--touch")) d.touch_name = argv[i + 1];
        else if (!strcmp(argv[i], "--keys")) d.keys_name = argv[i + 1];
        else goto usage;
    }
    if (load_config(argv[1], &d.cfg)) return 2;

    struct sigaction sa = { .sa_handler = on_signal };
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);

    d.kbd_fd = create_keyboard(&d.cfg);
    if (d.kbd_fd < 0) return 1;
    for (int f = 0; f < TG_MAX_FINGERS; f++) d.passes = d.passes || d.cfg.pass[f];

    int64_t retry_at = 0;
    while (!stopping) {
        if (now_us() >= retry_at && (d.touch_fd < 0 || d.keys_fd < 0)) {
            if (d.touch_fd < 0) open_touch(&d);
            if (d.keys_fd < 0) d.keys_fd = open_by_name(d.keys_name);
            retry_at = now_us() + RETRY_MS * 1000LL;
        }
        struct pollfd fds[2] = { { .fd = d.touch_fd, .events = POLLIN }, { .fd = d.keys_fd, .events = POLLIN } };
        int64_t wake = d.touch_fd >= 0 ? tg_next_deadline(&d.st) : INT64_MAX;
        if (d.touch_fd < 0 || d.keys_fd < 0) wake = wake < retry_at ? wake : retry_at;
        int timeout = -1;
        if (wake != INT64_MAX) {
            int64_t ms = (wake - now_us() + 999) / 1000;
            timeout = ms < 0 ? 0 : ms > 60000 ? 60000 : (int)ms;
        }
        if (poll(fds, 2, timeout) < 0 && errno != EINTR) {
            fprintf(stderr, "touchgestured: poll: %s\n", strerror(errno));
            break;
        }
        if (d.touch_fd >= 0 && fds[0].revents) read_events(&d, &d.touch_fd, d.touch_name);
        if (d.keys_fd >= 0 && fds[1].revents) read_events(&d, &d.keys_fd, d.keys_name);
        /* After the events, which carry earlier times, so deadlines are not taken out of order. */
        if (d.touch_fd >= 0) tg_advance(&d.st, now_us());
    }
    destroy_device(&d.pad_fd);
    destroy_device(&d.kbd_fd);
    return stopping ? 0 : 1;

usage:
    fprintf(stderr, "usage: touchgestured CONFIG [--touch NAME] [--keys NAME]\n");
    return 2;
}
