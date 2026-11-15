#define _GNU_SOURCE
#include "yasno_linux.h"
#include <linux/input.h>
#include <linux/uinput.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <dirent.h>

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define TEST(bit, array) ((array[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

int yl_open_input(const char *path) {
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    return fd >= 0 ? fd : -errno;
}
int yl_close(int fd) { return close(fd); }
int yl_access_ok(const char *path, int write) { return access(path, write ? (R_OK | W_OK) : R_OK) == 0; }

int yl_device_name(int fd, char *buffer, int length) {
    if (ioctl(fd, EVIOCGNAME(length - 1), buffer) < 0) { buffer[0] = 0; return -1; }
    buffer[length - 1] = 0;
    return 0;
}

int yl_device_kind(int fd) {
    unsigned long ev[NBITS(EV_MAX)] = {0}, keys[NBITS(KEY_MAX)] = {0}, rel[NBITS(REL_MAX)] = {0};
    if (ioctl(fd, EVIOCGBIT(0, sizeof(ev)), ev) < 0) return 0;
    int kind = 0;
    char name[256];
    yl_device_name(fd, name, sizeof name);
    if (strstr(name, "Yasno virtual keyboard")) kind |= YL_KIND_SELF;
    if (TEST(EV_KEY, ev)) {
        ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys);
        if (TEST(KEY_A, keys) && TEST(KEY_Z, keys) && TEST(KEY_SPACE, keys) && TEST(KEY_ENTER, keys)) kind |= YL_KIND_KEYBOARD;
        if (TEST(BTN_LEFT, keys) || TEST(BTN_TOUCH, keys)) kind |= YL_KIND_POINTER;
    }
    if (TEST(EV_REL, ev)) {
        ioctl(fd, EVIOCGBIT(EV_REL, sizeof(rel)), rel);
        if (TEST(REL_WHEEL, rel) || TEST(REL_X, rel)) kind |= YL_KIND_POINTER;
    }
    return kind;
}

/* 0, or -errno: -EBUSY when another program has the device. */
int yl_grab(int fd, int on) { return ioctl(fd, EVIOCGRAB, on ? 1 : 0) == 0 ? 0 : -errno; }
int yl_errno_busy(void) { return EBUSY; }
int yl_errno_access(void) { return EACCES; }

int yl_read_events(int fd, yl_event *out, int max) {
    struct input_event buffer[64];
    if (max > 64) max = 64;
    ssize_t n = read(fd, buffer, sizeof(struct input_event) * max);
    if (n < 0) return (errno == EAGAIN || errno == EINTR) ? 0 : -1;
    if (n == 0) return -1;
    int count = (int)(n / sizeof(struct input_event));
    for (int i = 0; i < count; i++) {
        out[i].time = buffer[i].input_event_sec + buffer[i].input_event_usec / 1e6;
        out[i].type = buffer[i].type; out[i].code = buffer[i].code; out[i].value = buffer[i].value;
    }
    return count;
}

int yl_leds(int fd) {
    unsigned long leds[NBITS(LED_MAX)] = {0};
    if (ioctl(fd, EVIOCGLED(sizeof(leds)), leds) < 0) return -1;
    return (int)(leds[0] & 0x7);
}

int yl_write_event(int fd, uint16_t type, uint16_t code, int32_t value) {
    struct input_event event;
    memset(&event, 0, sizeof event);
    event.type = type; event.code = code; event.value = value;
    for (;;) {
        ssize_t n = write(fd, &event, sizeof event);
        if (n == sizeof event) return 0;
        if (n < 0 && errno == EINTR) continue;
        return -1;
    }
}

int yl_uinput_create(const char *name) {
    int fd = open("/dev/uinput", O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return -1;
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_EVBIT, EV_MSC);
    ioctl(fd, UI_SET_EVBIT, EV_LED);
    ioctl(fd, UI_SET_EVBIT, EV_REP);
    ioctl(fd, UI_SET_MSCBIT, MSC_SCAN);
    for (int key = 1; key < 0x100; key++) ioctl(fd, UI_SET_KEYBIT, key);       /* keyboard keys */
    for (int key = 0x160; key < 0x2ff; key++) ioctl(fd, UI_SET_KEYBIT, key);   /* media and extra keys */
    for (int led = 0; led < LED_CNT; led++) ioctl(fd, UI_SET_LEDBIT, led);
    /* Keyboards with a built-in pointer (wireless combo receivers) keep their pointer working. */
    ioctl(fd, UI_SET_EVBIT, EV_REL);
    int rels[] = { REL_X, REL_Y, REL_WHEEL, REL_HWHEEL, REL_WHEEL_HI_RES, REL_HWHEEL_HI_RES };
    for (size_t i = 0; i < sizeof rels / sizeof rels[0]; i++) ioctl(fd, UI_SET_RELBIT, rels[i]);
    for (int button = BTN_LEFT; button <= BTN_TASK; button++) ioctl(fd, UI_SET_KEYBIT, button);
    struct uinput_setup setup;
    memset(&setup, 0, sizeof setup);
    setup.id.bustype = BUS_USB; setup.id.vendor = 0x5941; setup.id.product = 0x534e; setup.id.version = 1;
    snprintf(setup.name, UINPUT_MAX_NAME_SIZE, "%s", name);
    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) { close(fd); return -1; }
    return fd;
}

/* The /dev/input/eventN node of a device made through uinput, or "" if unknown. */
int yl_uinput_event_path(int fd, char *buffer, int length) {
    char sysname[64] = {0}, dir[160];
    buffer[0] = 0;
    if (ioctl(fd, UI_GET_SYSNAME(sizeof sysname), sysname) < 0) return -1;
    snprintf(dir, sizeof dir, "/sys/devices/virtual/input/%s", sysname);
    DIR *d = opendir(dir);
    if (!d) return -1;
    struct dirent *entry;
    while ((entry = readdir(d))) {
        if (!strncmp(entry->d_name, "event", 5)) { snprintf(buffer, length, "/dev/input/%s", entry->d_name); break; }
    }
    closedir(d);
    return buffer[0] ? 0 : -1;
}

void yl_uinput_destroy(int fd) { if (fd >= 0) { ioctl(fd, UI_DEV_DESTROY); close(fd); } }

int yl_poll(const int *fds, int count, int timeout_ms, int *ready) {
    struct pollfd items[128];
    if (count > 128) count = 128;
    for (int i = 0; i < count; i++) { items[i].fd = fds[i]; items[i].events = POLLIN; items[i].revents = 0; }
    int result = poll(items, count, timeout_ms);
    for (int i = 0; i < count; i++) ready[i] = (items[i].revents & (POLLIN | POLLERR | POLLHUP | POLLNVAL)) != 0;
    return result;
}

int yl_pipe(int fds[2]) { return pipe2(fds, O_NONBLOCK | O_CLOEXEC); }

int yl_keys_down(int fd) {
    unsigned long keys[NBITS(KEY_MAX)] = {0};
    if (ioctl(fd, EVIOCGKEY(sizeof(keys)), keys) < 0) return -1;
    int count = 0;
    for (size_t i = 0; i < NBITS(KEY_MAX); i++) count += __builtin_popcountl(keys[i]);
    return count;
}
