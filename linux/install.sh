#!/bin/sh
# Ясно for Linux: installs into your home folder (~/.local/share/yasno), sets up keyboard
# access once (asks for the administrator password), turns on start at login and starts Ясно.
# Run it from the unpacked folder:  ./install.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=${XDG_DATA_HOME:-$HOME/.local/share}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}
ROOT="$DATA/yasno"
APP="$ROOT/app"
BIN="$HOME/.local/bin"

say() { printf '%s\n' "$*"; }
if [ "$(id -u)" = 0 ]; then
    say "Запустите установку от своего пользователя, без sudo: ./install.sh"
    exit 1
fi
[ -x "$HERE/app/yasno" ] || { say "Не найден $HERE/app/yasno. Распакуйте архив целиком."; exit 1; }

as_root() {
    if command -v sudo >/dev/null 2>&1; then sudo "$@"
    elif command -v pkexec >/dev/null 2>&1; then pkexec "$@"
    else say "Нужны права администратора: выполните от root: $*"; return 1; fi
}

have_lib() { ldconfig -p 2>/dev/null | grep -q "$1" || ls /usr/lib*/"$1"* /usr/lib/*-linux-gnu/"$1"* >/dev/null 2>&1; }
have_dict() {
    for d in /usr/share/hunspell /usr/share/myspell /usr/share/myspell/dicts; do
        [ -f "$d/$1.dic" ] && return 0
    done
    return 1
}

# 1. What Ясно needs from the system: GTK 3, xkbcommon, Hunspell and its dictionaries.
missing=""
have_lib libgtk-3.so.0 || missing="$missing gtk"
have_lib libxkbcommon.so.0 || missing="$missing xkbcommon"
have_lib libhunspell-1.7.so.0 || missing="$missing hunspell"
have_dict ru_RU || missing="$missing ru"
have_dict uk_UA || missing="$missing uk"
have_dict en_US || missing="$missing en"
if [ -n "$missing" ]; then
    say "Устанавливаю недостающие пакеты:$missing"
    if command -v apt-get >/dev/null 2>&1; then
        de=hunspell-de-de; apt-cache show hunspell-de-de >/dev/null 2>&1 || de=hunspell-de-de-frami
        pkgs="libgtk-3-0 libxkbcommon0 libhunspell-1.7-0 hunspell-ru hunspell-uk hunspell-en-us $de"
        # Stale package lists give "Unable to locate package": refresh them once and retry.
        as_root apt-get install -y $pkgs || { as_root apt-get update && as_root apt-get install -y $pkgs; } || true
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y gtk3 libxkbcommon hunspell hunspell-ru hunspell-uk hunspell-en-US hunspell-de || true
    elif command -v zypper >/dev/null 2>&1; then
        as_root zypper --non-interactive install gtk3 libxkbcommon0 libhunspell-1_7-0 myspell-ru_RU myspell-uk_UA myspell-en_US myspell-de_DE || true
    elif command -v pacman >/dev/null 2>&1; then
        as_root pacman -S --needed --noconfirm gtk3 libxkbcommon hunspell hunspell-en_us hunspell-de || true
        say "Русский и украинский словари для Arch есть в AUR: hunspell-ru, hunspell-uk."
    else
        say "Установите сами: GTK 3, libxkbcommon, Hunspell и словари ru_RU, uk_UA, en_US."
    fi
    still=""
    have_lib libgtk-3.so.0 || still="$still GTK"
    have_lib libxkbcommon.so.0 || still="$still libxkbcommon"
    have_lib libhunspell-1.7.so.0 || still="$still Hunspell"
    have_dict ru_RU || still="$still словарь-ru"
    have_dict uk_UA || still="$still словарь-uk"
    have_dict en_US || still="$still словарь-en"
    [ -z "$still" ] || say "Не удалось установить:$still. Без них Ясно распознаёт слова хуже; поставьте их и перезапустите Ясно."
fi

# 2. Stop a running copy, then put the new one in place.
# Wait until it is really gone: one still holding its name on the bus takes over the new copy's start.
if pkill -u "$(id -u)" -x yasno 2>/dev/null; then
    i=0; while [ $i -lt 50 ] && pgrep -u "$(id -u)" -x yasno >/dev/null 2>&1; do sleep 0.1; i=$((i + 1)); done
    pkill -KILL -u "$(id -u)" -x yasno 2>/dev/null || true
fi
mkdir -p "$ROOT" "$BIN" "$DATA/applications" "$DATA/icons/hicolor/scalable/apps" "$ROOT/icons"
rm -rf "$APP.new"
cp -a "$HERE/app" "$APP.new"
touch "$APP.new/.yasno-install"
# Swapped, never removed first: an interrupted install keeps a working copy in place.
rm -rf "$APP.old"
[ ! -e "$APP" ] || mv "$APP" "$APP.old"
mv "$APP.new" "$APP" || { [ ! -e "$APP.old" ] || mv "$APP.old" "$APP"; exit 1; }
rm -rf "$APP.old"
ln -sf "$APP/yasno" "$BIN/yasno"
cp "$APP/icons/"*.svg "$DATA/icons/hicolor/scalable/apps/"
cp "$APP/icons/"*.svg "$ROOT/icons/"
sed "s|@EXEC@|$APP/yasno|" "$APP/io.github.mavesr.Yasno.desktop" > "$DATA/applications/io.github.mavesr.Yasno.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$DATA/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$DATA/icons/hicolor" 2>/dev/null || true

# 3. Keyboard access, once per computer. The rule also covers keyboards that key remappers
# (xremap, keyd) make, which the desktop alone does not give to the user.
if [ ! -f /etc/udev/rules.d/70-yasno.rules ] || ! "$APP/yasno" --check-access; then
    say "Ясно нужен доступ к клавиатуре. Система спросит пароль администратора."
    as_root "$APP/yasno" --setup-permissions || say "Доступ не настроен. Его можно дать позже кнопкой в окне Ясно."
    i=0; while [ $i -lt 20 ] && ! "$APP/yasno" --check-access; do sleep 0.25; i=$((i + 1)); done
fi

# 4. Start at login (can be turned off in the window), then start now.
mkdir -p "$CONFIG/autostart"
cat > "$CONFIG/autostart/io.github.mavesr.Yasno.desktop" <<ENTRY
[Desktop Entry]
Type=Application
Name=Ясно
Comment=Исправляет раскладку клавиатуры
Exec=$BIN/yasno --background
Icon=yasno
X-GNOME-Autostart-enabled=true
NoDisplay=true
ENTRY

cd "$HOME"
if command -v setsid >/dev/null 2>&1; then setsid "$APP/yasno" >/dev/null 2>&1 < /dev/null &
else nohup "$APP/yasno" >/dev/null 2>&1 < /dev/null & fi
say "Ясно $("$APP/yasno" --version) установлено в $APP и запущено."
if ! "$APP/yasno" --check-access; then
    say "Доступ к клавиатуре заработает после выхода из системы и повторного входа."
fi
case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*|*ubuntu*|*Unity*)
        say "В GNOME Ясно ставит своё расширение: если окно просит, выйдите из системы и войдите снова." ;;
esac
say "Удалить: $APP/uninstall.sh"
