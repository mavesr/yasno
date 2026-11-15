#include "yasno_linux.h"
#include <xkbcommon/xkbcommon.h>
#include <string.h>

int yl_xkb_table(const char *layout, const char *variant, const uint16_t *evdev_for_mac, char *text, uint8_t *dead) {
    struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!context) return -1;
    struct xkb_rule_names names = { .rules = NULL, .model = "pc105", .layout = layout,
                                    .variant = (variant && *variant) ? variant : NULL, .options = NULL };
    struct xkb_keymap *keymap = xkb_keymap_new_from_names(context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!keymap) { xkb_context_unref(context); return -2; }
    xkb_mod_index_t shift = xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_SHIFT);
    xkb_mod_index_t caps = xkb_keymap_mod_get_index(keymap, XKB_MOD_NAME_CAPS);
    memset(text, 0, 1024 * 8);
    memset(dead, 0, 1024);
    for (int combo = 0; combo < 4; combo++) {
        struct xkb_state *state = xkb_state_new(keymap);
        xkb_mod_mask_t depressed = (combo & 1) ? (1u << shift) : 0;
        xkb_mod_mask_t locked = (combo & 2) ? (1u << caps) : 0;
        xkb_state_update_mask(state, depressed, 0, locked, 0, 0, 0);
        for (int mac = 0; mac < 128; mac++) {
            uint16_t evdev = evdev_for_mac[mac];
            if (!evdev) continue;
            int position = mac | ((combo & 1) ? 0x100 : 0) | ((combo & 2) ? 0x200 : 0);
            xkb_keycode_t code = evdev + 8;
            xkb_keysym_t sym = xkb_state_key_get_one_sym(state, code);
            if (sym >= XKB_KEY_dead_grave && sym <= XKB_KEY_dead_greek) {
                dead[position] = 1;
                /* The table keeps the spacing form of a dead key, like UCKeyTranslate with no dead keys. */
                char name[64];
                xkb_keysym_get_name(sym, name, sizeof name);
                const char *spacing = NULL;
                if (sym == XKB_KEY_dead_grave) spacing = "`";
                else if (sym == XKB_KEY_dead_acute) spacing = "\xc2\xb4";
                else if (sym == XKB_KEY_dead_circumflex) spacing = "^";
                else if (sym == XKB_KEY_dead_tilde) spacing = "~";
                else if (sym == XKB_KEY_dead_diaeresis) spacing = "\xc2\xa8";
                if (spacing) strncpy(text + position * 8, spacing, 7);
                continue;
            }
            char buffer[16];
            int length = xkb_state_key_get_utf8(state, code, buffer, sizeof buffer);
            if (length > 0 && length < 8) memcpy(text + position * 8, buffer, length + 1);
        }
        xkb_state_unref(state);
    }
    xkb_keymap_unref(keymap);
    xkb_context_unref(context);
    return 0;
}
