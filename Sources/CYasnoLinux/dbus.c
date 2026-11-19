#include "yasno_linux.h"
#include <gio/gio.h>
#include <string.h>

static GDBusConnection *connection(int bus) {
    static GDBusConnection *session, *system;
    GDBusConnection **slot = bus ? &system : &session;
    if (!*slot) *slot = g_bus_get_sync(bus ? G_BUS_TYPE_SYSTEM : G_BUS_TYPE_SESSION, NULL, NULL);
    return *slot;
}

int yl_dbus_call(int bus, const char *dest, const char *path, const char *iface, const char *method,
                 const char *args, int timeout_ms, char *reply, int length) {
    if (length > 0) reply[0] = 0;
    GDBusConnection *c = connection(bus);
    if (!c) return -1;
    GVariant *parameters = NULL;
    if (args && *args) {
        GError *error = NULL;
        parameters = g_variant_parse(NULL, args, NULL, NULL, &error);
        if (!parameters) { if (error) { g_strlcpy(reply, error->message, length); g_error_free(error); } return -2; }
    }
    GError *error = NULL;
    GVariant *result = g_dbus_connection_call_sync(c, dest, path, iface, method, parameters, NULL,
                                                   G_DBUS_CALL_FLAGS_NO_AUTO_START, timeout_ms, NULL, &error);
    /* g_variant_parse gives a non-floating reference, which call_sync does not consume. */
    if (parameters) g_variant_unref(parameters);
    if (!result) { if (error) { g_strlcpy(reply, error->message, length); g_error_free(error); } return -3; }
    gchar *text = g_variant_print(result, FALSE);
    /* A reply cut to fit is not JSON any more: say so instead of reporting success. */
    gsize needed = g_strlcpy(reply, text, length);
    g_free(text);
    g_variant_unref(result);
    return needed < (gsize)length ? 0 : -4;
}

int yl_dbus_has_name(const char *name) {
    char reply[256];
    char args[300];
    g_snprintf(args, sizeof args, "('%s',)", name);
    if (yl_dbus_call(0, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                     args, 1000, reply, sizeof reply) != 0) return 0;
    return strstr(reply, "true") != NULL;
}
