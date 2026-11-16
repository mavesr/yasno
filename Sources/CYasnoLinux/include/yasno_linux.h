#ifndef YASNO_LINUX_H
#define YASNO_LINUX_H
#include <stdint.h>
#include <stddef.h>

/* ---- evdev / uinput (evdev.c) ---- */
typedef struct { double time; uint16_t type; uint16_t code; int32_t value; } yl_event;
enum { YL_KIND_KEYBOARD = 1, YL_KIND_POINTER = 2, YL_KIND_SELF = 4 };
int yl_open_input(const char *path);
int yl_device_kind(int fd);
int yl_device_name(int fd, char *buffer, int length);
int yl_grab(int fd, int on);
int yl_errno_busy(void);
int yl_errno_access(void);
int yl_uinput_event_path(int fd, char *buffer, int length);
/* Count of events read, 0 when none is ready, -1 when the device is gone. */
int yl_read_events(int fd, yl_event *out, int max);
int yl_leds(int fd);
int yl_write_event(int fd, uint16_t type, uint16_t code, int32_t value);
int yl_uinput_create(const char *name);
void yl_uinput_destroy(int fd);
int yl_close(int fd);
/* Waits up to timeout_ms for any of the descriptors; marks ready ones with 1. */
int yl_poll(const int *fds, int count, int timeout_ms, int *ready);
int yl_pipe(int fds[2]);
int yl_access_ok(const char *path, int write);
int yl_keys_down(int fd);

/* ---- XKB tables (xkb.c) ---- */
/* Fills text[position] (position = mac key | 0x100 shift | 0x200 caps) as UTF-8, 8 bytes each,
   and dead[position] = 1 for dead keys. evdev_for_mac maps a Mac key code (0..127) to evdev, 0 = none. */
int yl_xkb_table(const char *layout, const char *variant, const uint16_t *evdev_for_mac,
                 char *text /* 1024 * 8 */, uint8_t *dead /* 1024 */);

/* ---- X11 (x11.c, libX11 loaded at run time) ---- */
int yl_x11_open(void);
int yl_x11_group(void);
int yl_x11_lock_group(int group);
/* NUL-separated _XKB_RULES_NAMES: rules, model, layout, variant, options. Returns length. */
int yl_x11_rules(char *buffer, int length);
int yl_x11_active_class(char *buffer, int length);

/* ---- D-Bus through GIO (dbus.c) ---- */
/* Call with arguments in GVariant text format ("(uint32 1,)" or NULL); the reply is printed
   back as GVariant text. bus 0 = session. Returns 0 on success. */
int yl_dbus_call(int bus, const char *dest, const char *path, const char *iface, const char *method,
                 const char *args, int timeout_ms, char *reply, int length);
int yl_dbus_has_name(const char *name);

/* ---- user interface (ui.c, tray.c) ---- */
typedef struct {
    const char *status;
    const char *detail;
    const char *layouts;
    const char *update_message;
    const char *ignored_words;
    const char *excluded_apps;   /* "id\tname\n" lines */
    const char *setup_hint;      /* what is missing, empty when ready */
    const char *setup_button;    /* label of the setup button, empty for none */
    int enabled, monitoring, spelling, login, automatic_updates, update_available, update_busy;
    int corrections;
    int can_exclude;
    /* Input diagnostics (Diagnostics.swift). */
    const char *diagnostic_message;
    const char *diagnostic_repo;
    int diagnostics, diagnostic_events, diagnostic_queued, diagnostic_token, diagnostic_busy;
} yl_ui_state;

typedef struct {
    void (*toggle)(int which, int value);   /* 0 enabled, 1 spelling, 2 login, 3 automatic updates */
    void (*action)(int which);              /* see YL_ACTION_* */
    void (*ignored_changed)(const char *text);
    void (*remove_app)(const char *id);
    void (*started)(int background);
    void (*diagnostic_save)(const char *repo, const char *token, int replace_token);
} yl_ui_callbacks;

enum { YL_ACTION_CHECK_UPDATES = 0, YL_ACTION_SETUP = 1, YL_ACTION_QUIT = 2, YL_ACTION_EXCLUDE = 3,
       YL_ACTION_TOGGLE_PAUSE = 4, YL_ACTION_SHOW = 5, YL_ACTION_DIAGNOSTICS = 6, YL_ACTION_JOURNALS = 7,
       YL_ACTION_SEND_JOURNALS = 8, YL_ACTION_SHOW_DIAGNOSTICS = 9 };

int yl_ui_run(int argc, char **argv, const char *version, const yl_ui_callbacks *callbacks);
void yl_ui_post_state(const yl_ui_state *state);
void yl_ui_show(void);
void yl_ui_show_diagnostics(void);
/* GTK main thread only: a modal question; 1 when the person chose `ok`. */
int yl_ui_confirm(const char *title, const char *text, const char *ok);
void yl_ui_quit(void);
#endif
