#include "yasno_linux.h"
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <pthread.h>

/* libX11 is loaded only when an X11 session is used, so the program also starts without it. */
typedef void Display;
typedef unsigned long XID;
typedef unsigned long Atom;
typedef struct { unsigned char group, locked_group; unsigned short base_group, latched_group;
                 unsigned char mods, base_mods, latched_mods, locked_mods, compat_state, grab_mods, compat_grab_mods,
                 lookup_mods, compat_lookup_mods; unsigned short ptr_buttons; } XkbStateRec;
typedef struct { char *res_name; char *res_class; } XClassHint;

static void *library;
static Display *display;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Display *(*pXOpenDisplay)(const char *);
static int (*pXkbGetState)(Display *, unsigned int, XkbStateRec *);
static int (*pXkbLockGroup)(Display *, unsigned int, unsigned int);
static int (*pXSync)(Display *, int);
static int (*pXFlush)(Display *);
static Atom (*pXInternAtom)(Display *, const char *, int);
static XID (*pXDefaultRootWindow)(Display *);
static int (*pXGetWindowProperty)(Display *, XID, Atom, long, long, int, Atom, Atom *, int *, unsigned long *, unsigned long *, unsigned char **);
static int (*pXFree)(void *);
static int (*pXGetClassHint)(Display *, XID, XClassHint *);
static int (*pXSetErrorHandler)(void *);
static int (*pXInitThreads)(void);

static int ignore_errors(Display *d, void *e) { (void)d; (void)e; return 0; }

int yl_x11_open(void) {
    pthread_mutex_lock(&lock);
    if (display) { pthread_mutex_unlock(&lock); return 1; }
    if (!getenv("DISPLAY")) { pthread_mutex_unlock(&lock); return 0; }
    if (!library) library = dlopen("libX11.so.6", RTLD_NOW);
    if (!library) { pthread_mutex_unlock(&lock); return 0; }
    pXOpenDisplay = dlsym(library, "XOpenDisplay");
    pXkbGetState = dlsym(library, "XkbGetState");
    pXkbLockGroup = dlsym(library, "XkbLockGroup");
    pXSync = dlsym(library, "XSync");
    pXFlush = dlsym(library, "XFlush");
    pXInternAtom = dlsym(library, "XInternAtom");
    pXDefaultRootWindow = dlsym(library, "XDefaultRootWindow");
    pXGetWindowProperty = dlsym(library, "XGetWindowProperty");
    pXFree = dlsym(library, "XFree");
    pXGetClassHint = dlsym(library, "XGetClassHint");
    pXSetErrorHandler = dlsym(library, "XSetErrorHandler");
    if (!pXOpenDisplay || !pXkbGetState || !pXkbLockGroup || !pXSync) { pthread_mutex_unlock(&lock); return 0; }
    display = pXOpenDisplay(NULL);
    if (display && pXSetErrorHandler) pXSetErrorHandler((void *)ignore_errors);
    pthread_mutex_unlock(&lock);
    return display != NULL;
}

int yl_x11_group(void) {
    if (!yl_x11_open()) return -1;
    pthread_mutex_lock(&lock);
    XkbStateRec state; memset(&state, 0, sizeof state);
    int ok = pXkbGetState(display, 0x0100 /* XkbUseCoreKbd */, &state) == 0;
    pthread_mutex_unlock(&lock);
    return ok ? state.group : -1;
}

int yl_x11_lock_group(int group) {
    if (!yl_x11_open()) return -1;
    pthread_mutex_lock(&lock);
    int ok = pXkbLockGroup(display, 0x0100, (unsigned)group);
    pXSync(display, 0);
    pthread_mutex_unlock(&lock);
    return ok ? 0 : -1;
}

static int string_property(XID window, const char *name, Atom type, char *buffer, int length) {
    Atom atom = pXInternAtom(display, name, 0), actual; int format; unsigned long count = 0, after = 0;
    unsigned char *data = NULL;
    if (pXGetWindowProperty(display, window, atom, 0, 1024, 0, type, &actual, &format, &count, &after, &data) != 0 || !data) return -1;
    int n = (int)count < length - 1 ? (int)count : length - 1;
    memcpy(buffer, data, n); buffer[n] = 0;
    pXFree(data);
    return n;
}

int yl_x11_rules(char *buffer, int length) {
    if (!yl_x11_open()) return -1;
    pthread_mutex_lock(&lock);
    Atom string = pXInternAtom(display, "STRING", 0);
    int n = string_property(pXDefaultRootWindow(display), "_XKB_RULES_NAMES", string, buffer, length);
    pthread_mutex_unlock(&lock);
    return n;
}

int yl_x11_active_class(char *buffer, int length) {
    buffer[0] = 0;
    if (!yl_x11_open() || !pXGetClassHint) return -1;
    pthread_mutex_lock(&lock);
    Atom atom = pXInternAtom(display, "_NET_ACTIVE_WINDOW", 0), actual; int format; unsigned long count = 0, after = 0;
    unsigned char *data = NULL;
    int result = -1;
    if (pXGetWindowProperty(display, pXDefaultRootWindow(display), atom, 0, 1, 0, 33 /* XA_WINDOW */, &actual, &format, &count, &after, &data) == 0 && data && count == 1) {
        XID window = *(unsigned long *)data;
        XClassHint hint = {0, 0};
        if (window && pXGetClassHint(display, window, &hint)) {
            if (hint.res_class) { strncpy(buffer, hint.res_class, length - 1); buffer[length - 1] = 0; result = 0; }
            if (hint.res_name) pXFree(hint.res_name);
            if (hint.res_class) pXFree(hint.res_class);
        }
    }
    if (data) pXFree(data);
    pthread_mutex_unlock(&lock);
    return result;
}
