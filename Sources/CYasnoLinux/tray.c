/* Tray icon through StatusNotifierItem + com.canonical.dbusmenu: the protocol KDE, the Ubuntu
   GNOME AppIndicator extension, XFCE, Cinnamon and most panels show. Mirrors the macOS menu. */
#include "yasno_linux.h"
#include <gio/gio.h>
#include <string.h>
#include <unistd.h>

static const yl_ui_callbacks *cb;
static GDBusConnection *bus;
static guint revision = 1;
static char *status_text, *icon_path;
static int enabled = 1, monitoring = 0, can_exclude = 0, updates = 0, diagnostics = 0;
static guint watcher_id;
static char bus_name[128];

enum { ITEM_ROOT = 0, ITEM_STATUS = 1, ITEM_SEP1 = 2, ITEM_OPEN = 3, ITEM_PAUSE = 4, ITEM_EXCLUDE = 5,
       ITEM_UPDATES = 6, ITEM_SEP3 = 7, ITEM_DIAGNOSTICS = 8, ITEM_DIAGNOSTIC_SETTINGS = 9, ITEM_SEP2 = 10, ITEM_QUIT = 11 };

static const char *sni_xml =
    "<node><interface name='org.kde.StatusNotifierItem'>"
    "<property name='Category' type='s' access='read'/><property name='Id' type='s' access='read'/>"
    "<property name='Title' type='s' access='read'/><property name='Status' type='s' access='read'/>"
    "<property name='IconName' type='s' access='read'/><property name='IconThemePath' type='s' access='read'/>"
    "<property name='ToolTip' type='(sa(iiay)ss)' access='read'/><property name='ItemIsMenu' type='b' access='read'/>"
    "<property name='Menu' type='o' access='read'/>"
    "<method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>"
    "<method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>"
    "<signal name='NewIcon'/><signal name='NewToolTip'/><signal name='NewStatus'><arg type='s'/></signal>"
    "</interface></node>";

static const char *menu_xml =
    "<node><interface name='com.canonical.dbusmenu'>"
    "<property name='Version' type='u' access='read'/><property name='Status' type='s' access='read'/>"
    "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/><arg type='as' direction='in'/>"
    "<arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
    "<method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/><arg type='a(ia{sv})' direction='out'/></method>"
    "<method name='GetProperty'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='out'/></method>"
    "<method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/><arg type='v' direction='in'/><arg type='u' direction='in'/></method>"
    "<method name='EventGroup'><arg type='a(isvu)' direction='in'/><arg type='ai' direction='out'/></method>"
    "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>"
    "<method name='AboutToShowGroup'><arg type='ai' direction='in'/><arg type='ai' direction='out'/><arg type='ai' direction='out'/></method>"
    "<signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ia{s})'/></signal>"
    "<signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>"
    "</interface></node>";

static const char *icon_name(void) { return monitoring ? "yasno" : "yasno-paused"; }

static GVariant *item_properties(int id) {
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    const char *label = NULL;
    switch (id) {
    case ITEM_ROOT: g_variant_builder_add(&b, "{sv}", "children-display", g_variant_new_string("submenu")); break;
    case ITEM_STATUS: label = status_text ? status_text : "Ясно";
        g_variant_builder_add(&b, "{sv}", "enabled", g_variant_new_boolean(FALSE)); break;
    case ITEM_SEP1: case ITEM_SEP2: case ITEM_SEP3: g_variant_builder_add(&b, "{sv}", "type", g_variant_new_string("separator")); break;
    case ITEM_OPEN: label = "Открыть Ясно…"; break;
    case ITEM_PAUSE: label = enabled ? "Приостановить" : "Включить"; break;
    case ITEM_EXCLUDE: label = "Не работать в этом приложении";
        g_variant_builder_add(&b, "{sv}", "enabled", g_variant_new_boolean(can_exclude)); break;
    case ITEM_UPDATES: label = "Проверить обновления";
        g_variant_builder_add(&b, "{sv}", "visible", g_variant_new_boolean(updates)); break;
    case ITEM_DIAGNOSTICS: label = diagnostics ? "Выключить диагностику ✓" : "Включить диагностику ввода"; break;
    case ITEM_DIAGNOSTIC_SETTINGS: label = "Диагностика ввода…"; break;
    case ITEM_QUIT: label = "Завершить Ясно"; break;
    }
    if (label) g_variant_builder_add(&b, "{sv}", "label", g_variant_new_string(label));
    return g_variant_builder_end(&b);
}

static GVariant *layout(void) {
    GVariantBuilder children;
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    for (int id = ITEM_STATUS; id <= ITEM_QUIT; id++) {
        GVariant *empty = g_variant_new_array(G_VARIANT_TYPE_VARIANT, NULL, 0);
        g_variant_builder_add(&children, "v", g_variant_new("(i@a{sv}@av)", id, item_properties(id), empty));
    }
    return g_variant_new("(i@a{sv}av)", ITEM_ROOT, item_properties(ITEM_ROOT), &children);
}

static void clicked(int id) {
    if (!cb) return;
    switch (id) {
    case ITEM_OPEN: cb->action(YL_ACTION_SHOW); break;
    case ITEM_PAUSE: cb->action(YL_ACTION_TOGGLE_PAUSE); break;
    case ITEM_EXCLUDE: cb->action(YL_ACTION_EXCLUDE); break;
    case ITEM_UPDATES: cb->action(YL_ACTION_CHECK_UPDATES); cb->action(YL_ACTION_SHOW); break;
    case ITEM_DIAGNOSTICS: cb->action(YL_ACTION_DIAGNOSTICS); break;
    case ITEM_DIAGNOSTIC_SETTINGS: cb->action(YL_ACTION_SHOW_DIAGNOSTICS); break;
    case ITEM_QUIT: cb->action(YL_ACTION_QUIT); break;
    }
}

static void menu_call(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                      const gchar *method, GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)data;
    if (!strcmp(method, "GetLayout")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(u@(ia{sv}av))", revision, layout()));
    } else if (!strcmp(method, "GetGroupProperties")) {
        GVariantIter *ids; g_variant_get(params, "(aias)", &ids, NULL);
        GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a(ia{sv})"));
        gint32 id; int any = 0;
        while (g_variant_iter_next(ids, "i", &id)) { g_variant_builder_add(&b, "(i@a{sv})", id, item_properties(id)); any = 1; }
        if (!any) for (int i = ITEM_ROOT; i <= ITEM_QUIT; i++) g_variant_builder_add(&b, "(i@a{sv})", i, item_properties(i));
        g_variant_iter_free(ids);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(a(ia{sv}))", &b));
    } else if (!strcmp(method, "GetProperty")) {
        gint32 id; const gchar *name; g_variant_get(params, "(i&s)", &id, &name);
        GVariant *props = item_properties(id);
        GVariant *value = g_variant_lookup_value(props, name, NULL);
        g_variant_unref(g_variant_ref_sink(props));
        if (!value) value = g_variant_new_string("");
        g_dbus_method_invocation_return_value(inv, g_variant_new("(v)", value));
    } else if (!strcmp(method, "Event")) {
        gint32 id; const gchar *event; g_variant_get(params, "(i&svu)", &id, &event, NULL, NULL);
        if (!strcmp(event, "clicked")) clicked(id);
        g_dbus_method_invocation_return_value(inv, NULL);
    } else if (!strcmp(method, "EventGroup")) {
        GVariantIter *events; g_variant_get(params, "(a(isvu))", &events);
        gint32 id; const gchar *event; GVariant *v; guint32 t;
        while (g_variant_iter_next(events, "(i&svu)", &id, &event, &v, &t)) { if (!strcmp(event, "clicked")) clicked(id); g_variant_unref(v); }
        g_variant_iter_free(events);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(@ai)", g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0)));
    } else if (!strcmp(method, "AboutToShow")) {
        g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", FALSE));
    } else if (!strcmp(method, "AboutToShowGroup")) {
        GVariant *empty1 = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0), *empty2 = g_variant_new_array(G_VARIANT_TYPE_INT32, NULL, 0);
        g_dbus_method_invocation_return_value(inv, g_variant_new("(@ai@ai)", empty1, empty2));
    } else g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod", method);
}

static GVariant *menu_property(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                               const gchar *name, GError **error, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)error; (void)data;
    if (!strcmp(name, "Version")) return g_variant_new_uint32(3);
    return g_variant_new_string("normal");
}

static void sni_call(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                     const gchar *method, GVariant *params, GDBusMethodInvocation *inv, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)params; (void)data;
    if (!strcmp(method, "Activate") && cb) cb->action(YL_ACTION_SHOW);
    g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant *sni_property(GDBusConnection *c, const gchar *sender, const gchar *path, const gchar *iface,
                              const gchar *name, GError **error, gpointer data) {
    (void)c; (void)sender; (void)path; (void)iface; (void)error; (void)data;
    if (!strcmp(name, "Category")) return g_variant_new_string("ApplicationStatus");
    if (!strcmp(name, "Id")) return g_variant_new_string("yasno");
    if (!strcmp(name, "Title")) return g_variant_new_string("Ясно");
    if (!strcmp(name, "Status")) return g_variant_new_string("Active");
    if (!strcmp(name, "IconName")) return g_variant_new_string(icon_name());
    if (!strcmp(name, "IconThemePath")) return g_variant_new_string(icon_path ? icon_path : "");
    if (!strcmp(name, "ItemIsMenu")) return g_variant_new_boolean(FALSE);
    if (!strcmp(name, "Menu")) return g_variant_new_object_path("/MenuBar");
    if (!strcmp(name, "ToolTip")) {
        gchar *tip = g_strdup_printf("Ясно — %s", status_text ? status_text : "");
        GVariant *v = g_variant_new("(s@a(iiay)ss)", icon_name(), g_variant_new_array(G_VARIANT_TYPE("(iiay)"), NULL, 0), "Ясно", tip);
        g_free(tip);
        return v;
    }
    return NULL;
}

static void register_item(GDBusConnection *c, const gchar *name, const gchar *owner, gpointer data) {
    (void)name; (void)owner; (void)data;
    g_dbus_connection_call(c, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher",
                           "RegisterStatusNotifierItem", g_variant_new("(s)", bus_name), NULL, G_DBUS_CALL_FLAGS_NONE, 2000, NULL, NULL, NULL);
}

void yl_tray_start(const yl_ui_callbacks *callbacks) {
    cb = callbacks;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
    if (!bus) return;
    const char *data = g_get_user_data_dir();
    icon_path = g_build_filename(data, "yasno", "icons", NULL);
    static const GDBusInterfaceVTable sni_vtable = { sni_call, sni_property, NULL, {0} };
    static const GDBusInterfaceVTable menu_vtable = { menu_call, menu_property, NULL, {0} };
    GDBusNodeInfo *sni = g_dbus_node_info_new_for_xml(sni_xml, NULL), *menu = g_dbus_node_info_new_for_xml(menu_xml, NULL);
    g_dbus_connection_register_object(bus, "/StatusNotifierItem", sni->interfaces[0], &sni_vtable, NULL, NULL, NULL);
    g_dbus_connection_register_object(bus, "/MenuBar", menu->interfaces[0], &menu_vtable, NULL, NULL, NULL);
    g_snprintf(bus_name, sizeof bus_name, "org.kde.StatusNotifierItem-%d-1", (int)getpid());
    g_bus_own_name_on_connection(bus, bus_name, G_BUS_NAME_OWNER_FLAGS_NONE, NULL, NULL, NULL, NULL);
    /* Register now and again whenever a panel (re)starts its watcher. */
    watcher_id = g_bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher", G_BUS_NAME_WATCHER_FLAGS_NONE,
                                                register_item, NULL, NULL, NULL);
}

void yl_tray_update(const yl_ui_state *state) {
    if (!bus) return;
    int changed = !status_text || strcmp(status_text, state->status) || enabled != state->enabled ||
                  monitoring != state->monitoring || can_exclude != state->can_exclude || updates != state->update_available ||
                  diagnostics != state->diagnostics;
    if (!changed) return;
    int icon_changed = monitoring != state->monitoring;
    g_free(status_text); status_text = g_strdup(state->status);
    enabled = state->enabled; monitoring = state->monitoring; can_exclude = state->can_exclude; updates = state->update_available;
    diagnostics = state->diagnostics;
    revision++;
    g_dbus_connection_emit_signal(bus, NULL, "/MenuBar", "com.canonical.dbusmenu", "LayoutUpdated", g_variant_new("(ui)", revision, 0), NULL);
    g_dbus_connection_emit_signal(bus, NULL, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewToolTip", NULL, NULL);
    if (icon_changed) g_dbus_connection_emit_signal(bus, NULL, "/StatusNotifierItem", "org.kde.StatusNotifierItem", "NewIcon", NULL, NULL);
}
