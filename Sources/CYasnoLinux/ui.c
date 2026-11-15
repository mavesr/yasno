#include "yasno_linux.h"
#include <gtk/gtk.h>
#include <string.h>

void yl_tray_start(const yl_ui_callbacks *callbacks);
void yl_tray_update(const yl_ui_state *state);

static GtkApplication *application;
static GtkWidget *window, *exceptions_window;
static const yl_ui_callbacks *cb;
static const char *app_version = "";
static int background_launch;
static int updating; /* set while the state is applied, so programmatic changes do not echo back */

static GtkWidget *dot, *status_label, *auto_switch, *layouts_label, *setup_box, *setup_label, *setup_button;
static GtkWidget *spelling_check, *login_check, *update_box, *update_check, *update_button, *update_caption;
static GtkWidget *detail_label, *corrections_label, *words_view, *apps_box;
static char *last_apps;

typedef struct { yl_ui_state s; } owned_state;

static char *dup0(const char *s) { return g_strdup(s ? s : ""); }

static owned_state *copy_state(const yl_ui_state *in) {
    owned_state *o = g_new0(owned_state, 1);
    o->s = *in;
    o->s.status = dup0(in->status); o->s.detail = dup0(in->detail); o->s.layouts = dup0(in->layouts);
    o->s.update_message = dup0(in->update_message); o->s.ignored_words = dup0(in->ignored_words);
    o->s.excluded_apps = dup0(in->excluded_apps); o->s.setup_hint = dup0(in->setup_hint);
    o->s.setup_button = dup0(in->setup_button);
    return o;
}

static void free_state(owned_state *o) {
    g_free((char *)o->s.status); g_free((char *)o->s.detail); g_free((char *)o->s.layouts);
    g_free((char *)o->s.update_message); g_free((char *)o->s.ignored_words); g_free((char *)o->s.excluded_apps);
    g_free((char *)o->s.setup_hint); g_free((char *)o->s.setup_button);
    g_free(o);
}

static owned_state *current;

static GtkWidget *label(const char *text, const char *css_class, gboolean wrap) {
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    if (wrap) { gtk_label_set_line_wrap(GTK_LABEL(l), TRUE); gtk_label_set_max_width_chars(GTK_LABEL(l), 52); }
    if (css_class) gtk_style_context_add_class(gtk_widget_get_style_context(l), css_class);
    return l;
}

static void remove_clicked(GtkButton *button, gpointer data) {
    (void)data;
    const char *id = g_object_get_data(G_OBJECT(button), "app-id");
    if (cb && cb->remove_app && id) cb->remove_app(id);
}

static void rebuild_apps(const char *apps) {
    if (!apps_box) return;
    if (last_apps && strcmp(last_apps, apps) == 0) return;
    g_free(last_apps); last_apps = g_strdup(apps);
    GList *children = gtk_container_get_children(GTK_CONTAINER(apps_box));
    for (GList *i = children; i; i = i->next) gtk_widget_destroy(GTK_WIDGET(i->data));
    g_list_free(children);
    gchar **lines = g_strsplit(apps, "\n", -1);
    for (gchar **line = lines; *line; line++) {
        if (!**line) continue;
        gchar **parts = g_strsplit(*line, "\t", 2);
        const char *id = parts[0], *name = parts[1] ? parts[1] : parts[0];
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_box_pack_start(GTK_BOX(row), label(name, NULL, FALSE), TRUE, TRUE, 0);
        GtkWidget *remove = gtk_button_new_from_icon_name("list-remove-symbolic", GTK_ICON_SIZE_BUTTON);
        gtk_button_set_relief(GTK_BUTTON(remove), GTK_RELIEF_NONE);
        gchar *tip = g_strdup_printf("Удалить исключение %s", name);
        gtk_widget_set_tooltip_text(remove, tip); g_free(tip);
        g_object_set_data_full(G_OBJECT(remove), "app-id", g_strdup(id), g_free);
        g_signal_connect(remove, "clicked", G_CALLBACK(remove_clicked), NULL);
        gtk_box_pack_end(GTK_BOX(row), remove, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(apps_box), row, FALSE, FALSE, 0);
        g_strfreev(parts);
    }
    g_strfreev(lines);
    gtk_widget_show_all(apps_box);
}

static void apply_state(void) {
    if (!current || !window) return;
    yl_ui_state *s = &current->s;
    updating = 1;
    gtk_label_set_text(GTK_LABEL(status_label), s->status);
    GtkStyleContext *dc = gtk_widget_get_style_context(dot);
    gtk_style_context_remove_class(dc, s->monitoring ? "dot-off" : "dot-on");
    gtk_style_context_add_class(dc, s->monitoring ? "dot-on" : "dot-off");
    gtk_switch_set_active(GTK_SWITCH(auto_switch), s->enabled);
    gtk_label_set_text(GTK_LABEL(layouts_label), (s->layouts && *s->layouts) ? s->layouts : "Українська · Русский · English · Deutsch");
    gtk_widget_set_visible(setup_box, s->setup_hint && *s->setup_hint);
    gtk_label_set_text(GTK_LABEL(setup_label), s->setup_hint);
    gtk_widget_set_visible(setup_button, s->setup_button && *s->setup_button);
    gtk_button_set_label(GTK_BUTTON(setup_button), s->setup_button);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(spelling_check), s->spelling);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(login_check), s->login);
    gtk_widget_set_visible(update_box, s->update_available);
    gtk_toggle_button_set_active(GTK_TOGGLE_BUTTON(update_check), s->automatic_updates);
    gtk_widget_set_sensitive(update_button, !s->update_busy);
    gtk_label_set_text(GTK_LABEL(update_caption), (s->update_message && *s->update_message) ? s->update_message
                       : "Каждый день в 21:00 с GitHub · доступ к клавиатуре сохраняется");
    gtk_widget_set_visible(detail_label, s->detail && *s->detail);
    gtk_label_set_text(GTK_LABEL(detail_label), s->detail);
    gchar *count = g_strdup_printf("Исправлено: %d", s->corrections);
    gtk_label_set_text(GTK_LABEL(corrections_label), count); g_free(count);
    if (words_view) {
        GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(words_view));
        GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
        gchar *text = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
        if (strcmp(text, s->ignored_words) != 0 && !gtk_widget_has_focus(words_view)) gtk_text_buffer_set_text(buffer, s->ignored_words, -1);
        g_free(text);
    }
    rebuild_apps(s->excluded_apps);
    updating = 0;
}

static gboolean apply_posted(gpointer data) {
    if (current) free_state(current);
    current = data;
    apply_state();
    yl_tray_update(&current->s);
    return G_SOURCE_REMOVE;
}

void yl_ui_post_state(const yl_ui_state *state) { g_idle_add(apply_posted, copy_state(state)); }

static void on_switch(GObject *object, GParamSpec *spec, gpointer data) {
    (void)spec; (void)data;
    if (!updating && cb) cb->toggle(0, gtk_switch_get_active(GTK_SWITCH(object)));
}
static void on_check(GtkToggleButton *button, gpointer which) {
    if (!updating && cb) cb->toggle(GPOINTER_TO_INT(which), gtk_toggle_button_get_active(button));
}
static void on_action(GtkButton *button, gpointer which) { (void)button; if (cb) cb->action(GPOINTER_TO_INT(which)); }

static void words_changed(GtkTextBuffer *buffer, gpointer data) {
    (void)data;
    if (updating || !cb) return;
    GtkTextIter a, b; gtk_text_buffer_get_bounds(buffer, &a, &b);
    gchar *text = gtk_text_buffer_get_text(buffer, &a, &b, FALSE);
    cb->ignored_changed(text);
    g_free(text);
}

static void close_exceptions(GtkButton *button, gpointer data) { (void)button; (void)data; gtk_widget_hide(exceptions_window); }

static void show_exceptions(GtkButton *button, gpointer data) {
    (void)button; (void)data;
    if (!exceptions_window) {
        exceptions_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
        gtk_window_set_title(GTK_WINDOW(exceptions_window), "Исключения");
        gtk_window_set_transient_for(GTK_WINDOW(exceptions_window), GTK_WINDOW(window));
        gtk_window_set_modal(GTK_WINDOW(exceptions_window), TRUE);
        gtk_window_set_resizable(GTK_WINDOW(exceptions_window), FALSE);
        gtk_window_set_default_size(GTK_WINDOW(exceptions_window), 430, -1);
        g_signal_connect(exceptions_window, "delete-event", G_CALLBACK(gtk_widget_hide_on_delete), NULL);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
        gtk_container_set_border_width(GTK_CONTAINER(box), 24);
        gtk_box_pack_start(GTK_BOX(box), label("Исключения", "title2", FALSE), FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), label("Не менять эти слова", "headline", FALSE), FALSE, FALSE, 0);
        GtkWidget *scroll = gtk_scrolled_window_new(NULL, NULL);
        gtk_widget_set_size_request(scroll, -1, 80);
        gtk_scrolled_window_set_shadow_type(GTK_SCROLLED_WINDOW(scroll), GTK_SHADOW_IN);
        words_view = gtk_text_view_new();
        gtk_text_view_set_monospace(GTK_TEXT_VIEW(words_view), TRUE);
        AtkObject *a11y = gtk_widget_get_accessible(words_view);
        if (a11y) atk_object_set_name(a11y, "Слова исключения");
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(words_view)), current ? current->s.ignored_words : "", -1);
        g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(words_view)), "changed", G_CALLBACK(words_changed), NULL);
        gtk_container_add(GTK_CONTAINER(scroll), words_view);
        gtk_box_pack_start(GTK_BOX(box), scroll, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), label("По одному слову в строке. Сохраняются автоматически.", "caption", TRUE), FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), label("Не работать в приложениях", "headline", FALSE), FALSE, FALSE, 0);
        GtkWidget *apps_scroll = gtk_scrolled_window_new(NULL, NULL);
        gtk_widget_set_size_request(apps_scroll, -1, 110);
        apps_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
        gtk_container_set_border_width(GTK_CONTAINER(apps_box), 8);
        gtk_container_add(GTK_CONTAINER(apps_scroll), apps_box);
        gtk_box_pack_start(GTK_BOX(box), apps_scroll, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), label("Добавить приложение можно через значок Ясно в трее: пункт «Не работать в этом приложении» относится к окну, в котором вы печатали последним.", "caption", TRUE), FALSE, FALSE, 0);
        GtkWidget *done = gtk_button_new_with_label("Готово");
        gtk_style_context_add_class(gtk_widget_get_style_context(done), "suggested-action");
        g_signal_connect(done, "clicked", G_CALLBACK(close_exceptions), NULL);
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_box_pack_end(GTK_BOX(row), done, FALSE, FALSE, 0);
        gtk_box_pack_start(GTK_BOX(box), row, FALSE, FALSE, 0);
        gtk_container_add(GTK_CONTAINER(exceptions_window), box);
        if (last_apps) { char *apps = last_apps; last_apps = NULL; rebuild_apps(apps); g_free(apps); }
        else if (current) rebuild_apps(current->s.excluded_apps);
    }
    gtk_widget_show_all(exceptions_window);
    gtk_window_present(GTK_WINDOW(exceptions_window));
}

static GtkWidget *feature(const char *icon, const char *title, const char *subtitle) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 13);
    GtkWidget *image = gtk_image_new_from_icon_name(icon, GTK_ICON_SIZE_LARGE_TOOLBAR);
    gtk_widget_set_valign(image, GTK_ALIGN_START);
    gtk_style_context_add_class(gtk_widget_get_style_context(image), "accent");
    gtk_box_pack_start(GTK_BOX(row), image, FALSE, FALSE, 0);
    GtkWidget *text = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3);
    gtk_box_pack_start(GTK_BOX(text), label(title, "feature-title", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(text), label(subtitle, "secondary", TRUE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(row), text, TRUE, TRUE, 0);
    return row;
}

static const char *css =
    "window.yasno { background-color: @theme_bg_color; }"
    ".card { background-color: @theme_base_color; border-radius: 16px; padding: 18px; }"
    ".app-title { font-size: 29px; font-weight: 600; }"
    ".subtitle, .secondary, .caption { color: alpha(@theme_fg_color, 0.62); }"
    ".subtitle { font-size: 13px; } .secondary { font-size: 12px; } .caption { font-size: 11px; }"
    ".version { font-family: monospace; font-size: 11px; color: alpha(@theme_fg_color, 0.4); }"
    ".status { font-weight: 600; font-size: 14px; }"
    ".feature-title { font-weight: 500; font-size: 13px; }"
    ".footer { font-size: 10px; color: alpha(@theme_fg_color, 0.62); }"
    ".title2 { font-size: 20px; font-weight: 700; } .headline { font-weight: 600; }"
    ".accent { color: #2b6e64; }"
    ".logo { background-color: alpha(#2b6e64, 0.09); border-radius: 16px; padding: 13px; color: #2b6e64; }"
    ".dot-on { color: #2b6e64; } .dot-off { color: #e8912d; }";

static void build_window(GtkApplication *app) {
    window = gtk_application_window_new(app);
    gtk_window_set_title(GTK_WINDOW(window), "Ясно");
    gtk_window_set_resizable(GTK_WINDOW(window), FALSE);
    gtk_window_set_icon_name(GTK_WINDOW(window), "yasno");
    gtk_style_context_add_class(gtk_widget_get_style_context(window), "yasno");
    g_signal_connect(window, "delete-event", G_CALLBACK(gtk_widget_hide_on_delete), NULL);
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 22);
    gtk_container_set_border_width(GTK_CONTAINER(root), 28);
    gtk_widget_set_size_request(root, 480, -1);

    GtkWidget *header = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14);
    GtkWidget *logo = gtk_image_new_from_icon_name("input-keyboard-symbolic", GTK_ICON_SIZE_DND);
    gtk_image_set_pixel_size(GTK_IMAGE(logo), 32);
    gtk_style_context_add_class(gtk_widget_get_style_context(logo), "logo");
    gtk_widget_set_valign(logo, GTK_ALIGN_START);
    gtk_box_pack_start(GTK_BOX(header), logo, FALSE, FALSE, 0);
    GtkWidget *titles = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_box_pack_start(GTK_BOX(titles), label("Ясно", "app-title", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(titles), label("Ваши слова. Нужная раскладка.", "subtitle", FALSE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(header), titles, TRUE, TRUE, 0);
    GtkWidget *version = label(app_version, "version", FALSE);
    gtk_widget_set_valign(version, GTK_ALIGN_START);
    gtk_box_pack_end(GTK_BOX(header), version, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), header, FALSE, FALSE, 0);

    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_style_context_add_class(gtk_widget_get_style_context(card), "card");
    GtkWidget *status_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    dot = gtk_label_new("●");
    gtk_style_context_add_class(gtk_widget_get_style_context(dot), "dot-off");
    gtk_box_pack_start(GTK_BOX(status_row), dot, FALSE, FALSE, 0);
    status_label = label("Подготовка…", "status", FALSE);
    gtk_box_pack_start(GTK_BOX(status_row), status_label, TRUE, TRUE, 0);
    auto_switch = gtk_switch_new();
    gtk_widget_set_valign(auto_switch, GTK_ALIGN_CENTER);
    gtk_widget_set_tooltip_text(auto_switch, "Автоматическое исправление раскладки");
    AtkObject *a11y = gtk_widget_get_accessible(auto_switch);
    if (a11y) atk_object_set_name(a11y, "Автоматическое исправление раскладки");
    g_signal_connect(auto_switch, "notify::active", G_CALLBACK(on_switch), NULL);
    gtk_box_pack_end(GTK_BOX(status_row), auto_switch, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), status_row, FALSE, FALSE, 0);
    layouts_label = label("Українська · Русский · English · Deutsch", "secondary", TRUE);
    gtk_box_pack_start(GTK_BOX(card), layouts_label, FALSE, FALSE, 0);
    setup_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *pending = gtk_image_new_from_icon_name("dialog-warning-symbolic", GTK_ICON_SIZE_BUTTON);
    gtk_style_context_add_class(gtk_widget_get_style_context(pending), "dot-off");
    gtk_widget_set_valign(pending, GTK_ALIGN_START);
    gtk_box_pack_start(GTK_BOX(setup_box), pending, FALSE, FALSE, 0);
    setup_label = label("", NULL, TRUE);
    gtk_box_pack_start(GTK_BOX(setup_box), setup_label, TRUE, TRUE, 0);
    setup_button = gtk_button_new_with_label("Настроить");
    gtk_widget_set_valign(setup_button, GTK_ALIGN_CENTER);
    g_signal_connect(setup_button, "clicked", G_CALLBACK(on_action), GINT_TO_POINTER(YL_ACTION_SETUP));
    gtk_box_pack_end(GTK_BOX(setup_box), setup_button, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(card), setup_box, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), card, FALSE, FALSE, 0);

    GtkWidget *features = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    gtk_box_pack_start(GTK_BOX(features), feature("document-edit-symbolic", "Во время набора",
        "Исправляет уверенно распознанное слово и адрес сайта до пробела. Короткие и неоднозначные слова проверяет при завершении."), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(features), feature("edit-undo-symbolic", "Один короткий Shift",
        "Преобразует только что набранное слово. После автозамены — отмена. В пустом поле — следующий язык."), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(features), feature("preferences-desktop-locale-symbolic", "Русский и украинский отдельно",
        "При неоднозначности — ваш выбор языка; правильные слова сохраняются."), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), features, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL), FALSE, FALSE, 0);

    GtkWidget *spelling = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    spelling_check = gtk_check_button_new_with_label("Исправлять опечатки");
    g_signal_connect(spelling_check, "toggled", G_CALLBACK(on_check), GINT_TO_POINTER(1));
    gtk_box_pack_start(GTK_BOX(spelling), spelling_check, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(spelling), label("В словах, набранных не в той раскладке · после пробела · короткий Shift — отменить", "caption", TRUE), FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), spelling, FALSE, FALSE, 0);

    GtkWidget *login_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    login_check = gtk_check_button_new_with_label("Запускать при входе");
    g_signal_connect(login_check, "toggled", G_CALLBACK(on_check), GINT_TO_POINTER(2));
    gtk_box_pack_start(GTK_BOX(login_row), login_check, FALSE, FALSE, 0);
    GtkWidget *exceptions = gtk_button_new_with_label("Исключения…");
    g_signal_connect(exceptions, "clicked", G_CALLBACK(show_exceptions), NULL);
    gtk_box_pack_end(GTK_BOX(login_row), exceptions, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), login_row, FALSE, FALSE, 0);

    update_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    GtkWidget *update_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    update_check = gtk_check_button_new_with_label("Обновлять автоматически");
    g_signal_connect(update_check, "toggled", G_CALLBACK(on_check), GINT_TO_POINTER(3));
    gtk_box_pack_start(GTK_BOX(update_row), update_check, FALSE, FALSE, 0);
    update_button = gtk_button_new_with_label("Проверить сейчас");
    g_signal_connect(update_button, "clicked", G_CALLBACK(on_action), GINT_TO_POINTER(YL_ACTION_CHECK_UPDATES));
    gtk_box_pack_end(GTK_BOX(update_row), update_button, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(update_box), update_row, FALSE, FALSE, 0);
    update_caption = label("Каждый день в 21:00 с GitHub", "caption", TRUE);
    gtk_box_pack_start(GTK_BOX(update_box), update_caption, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), update_box, FALSE, FALSE, 0);

    detail_label = label("", "caption", TRUE);
    gtk_box_pack_start(GTK_BOX(root), detail_label, FALSE, FALSE, 0);

    GtkWidget *footer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *shield = gtk_image_new_from_icon_name("security-high-symbolic", GTK_ICON_SIZE_MENU);
    gtk_style_context_add_class(gtk_widget_get_style_context(shield), "footer");
    gtk_box_pack_start(GTK_BOX(footer), shield, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(footer), label("На вашем компьютере · без истории ввода", "footer", FALSE), FALSE, FALSE, 0);
    corrections_label = label("Исправлено: 0", "footer", FALSE);
    gtk_box_pack_end(GTK_BOX(footer), corrections_label, FALSE, FALSE, 0);
    gtk_box_pack_start(GTK_BOX(root), footer, FALSE, FALSE, 0);

    gtk_container_add(GTK_CONTAINER(window), root);
    gtk_widget_show_all(root);
    apply_state();
}

void yl_ui_show(void) {
    if (!window) return;
    gtk_widget_show(window);
    gtk_window_present(GTK_WINDOW(window));
}

static gboolean show_idle(gpointer data) { (void)data; yl_ui_show(); return G_SOURCE_REMOVE; }
static gboolean quit_idle(gpointer data) { (void)data; if (application) g_application_quit(G_APPLICATION(application)); return G_SOURCE_REMOVE; }
void yl_ui_quit(void) { g_idle_add(quit_idle, NULL); }

static int activations;
static void activate(GtkApplication *app, gpointer data) {
    (void)data;
    if (!window) build_window(app);
    if (activations++ == 0 && background_launch) return;
    g_idle_add(show_idle, NULL);
}

static void startup(GApplication *app, gpointer data) {
    (void)data;
    g_application_hold(app);
    yl_tray_start(cb);
    if (cb && cb->started) cb->started(background_launch);
}

int yl_ui_run(int argc, char **argv, const char *version, const yl_ui_callbacks *callbacks) {
    cb = callbacks;
    app_version = version;
    for (int i = 1; i < argc; i++) if (strcmp(argv[i], "--background") == 0) background_launch = 1;
    g_set_prgname("yasno");
    g_set_application_name("Ясно");
    application = gtk_application_new("io.github.mavesr.Yasno", G_APPLICATION_FLAGS_NONE);
    g_signal_connect(application, "startup", G_CALLBACK(startup), NULL);
    g_signal_connect(application, "activate", G_CALLBACK(activate), NULL);
    char *args[] = { argv[0], NULL };
    int status = g_application_run(G_APPLICATION(application), 1, args);
    g_object_unref(application);
    return status;
}
