#!/bin/sh
# Ясно for Linux in one command:
#   curl -fsSL https://raw.githubusercontent.com/mavesr/yasno/main/linux/get.sh | sh
# Finds the newest linux-v… release, checks its SHA-256 and runs its install.sh.
set -eu
REPO=mavesr/yasno
ARCH=$(uname -m)
[ "$ARCH" = arm64 ] && ARCH=aarch64
command -v curl >/dev/null 2>&1 || { echo "Нужен curl: sudo apt install curl"; exit 1; }
# The newest linux-v… release that has an archive for this processor.
TAGS=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=50" \
      | grep -o '"tag_name": *"linux-v[0-9.]*"' | sed 's/.*"\(linux-v[0-9.]*\)"/\1/')
TAG=
for CANDIDATE in $TAGS; do
  if curl -fsL -r 0-0 -o /dev/null "https://github.com/$REPO/releases/download/$CANDIDATE/yasno-linux-${CANDIDATE#linux-v}-$ARCH.tar.gz"; then
    TAG=$CANDIDATE; break
  fi
done
[ -n "$TAG" ] || { echo "Не нашёл выпуск Ясно для Linux ($ARCH)."; exit 1; }
VERSION=${TAG#linux-v}
NAME="yasno-linux-$VERSION-$ARCH"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
echo "Скачиваю Ясно $VERSION ($ARCH)…"
curl -fsSLO "https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz"
curl -fsSLO "https://github.com/$REPO/releases/download/$TAG/$NAME.tar.gz.sha256"
sha256sum -c "$NAME.tar.gz.sha256" >/dev/null || { echo "Архив не совпал с контрольной суммой."; exit 1; }
tar -xzf "$NAME.tar.gz"
# install.sh asks for the password through sudo, which needs the terminal even under "| sh".
if (exec < /dev/tty) 2>/dev/null; then "./$NAME/install.sh" < /dev/tty; else "./$NAME/install.sh"; fi
