#!/bin/sh
# Removes Ясно from your home folder. Settings (~/.config/yasno) stay unless you pass --purge.
set -u
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
APP="$DATA/yasno/app"
pkill -u "$(id -u)" -x yasno 2>/dev/null && sleep 1
if [ -f /etc/udev/rules.d/70-yasno.rules ] && [ -x "$APP/yasno" ]; then
    echo "Убираю доступ к клавиатуре (спросит пароль администратора)."
    if command -v sudo >/dev/null 2>&1; then sudo "$APP/yasno" --remove-permissions; else pkexec "$APP/yasno" --remove-permissions; fi
fi
command -v gnome-extensions >/dev/null 2>&1 && gnome-extensions disable yasno@mavesr.github.io 2>/dev/null
rm -rf "$DATA/gnome-shell/extensions/yasno@mavesr.github.io"
rm -f "$HOME/.local/bin/yasno" "$DATA/applications/io.github.mavesr.Yasno.desktop" \
      "$CONFIG/autostart/io.github.mavesr.Yasno.desktop" \
      "$DATA/icons/hicolor/scalable/apps/yasno.svg" "$DATA/icons/hicolor/scalable/apps/yasno-paused.svg"
rm -rf "$DATA/yasno"
[ "${1:-}" = "--purge" ] && rm -rf "$CONFIG/yasno"
echo "Ясно удалено."
