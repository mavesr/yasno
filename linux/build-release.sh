#!/bin/sh
# Builds the Linux release archive: dist/yasno-linux-<version>-<arch>.tar.gz and its .sha256.
# Build on the oldest system the release should run on (Ubuntu 22.04: glibc 2.35), with
# Swift 6.1 and libgtk-3-dev, libxkbcommon-dev installed. The Swift runtime is linked in.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/.*current = "\(.*\)".*/\1/p' Sources/YasnoLinux/Version.swift)
ARCH=$(uname -m)
SCRATCH=${YASNO_SCRATCH:-.build}
swift build -c release --static-swift-stdlib --scratch-path "$SCRATCH" --product yasno
BUILD="$SCRATCH/release"
NAME="yasno-linux-$VERSION-$ARCH"
STAGE="dist/$NAME"
rm -rf "$STAGE" "dist/$NAME.tar.gz" "dist/$NAME.tar.gz.sha256"
mkdir -p "$STAGE/app"
cp "$BUILD/yasno" "$STAGE/app/yasno"
strip "$STAGE/app/yasno"
cp -R "$BUILD/Yasno_SwitchCore.resources" "$STAGE/app/"
cp -R linux/gnome-extension linux/icons "$STAGE/app/"
cp linux/io.github.mavesr.Yasno.desktop linux/uninstall.sh "$STAGE/app/"
cp linux/install.sh "$STAGE/install.sh"
cp linux/README.txt "$STAGE/README.txt"
REPORTED=$("$STAGE/app/yasno" --version)
[ "$REPORTED" = "$VERSION" ] || { echo "built binary reports $REPORTED, expected $VERSION" >&2; exit 1; }
tar -C dist -czf "dist/$NAME.tar.gz" --owner=0 --group=0 "$NAME"
(cd dist && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
ls -l "dist/$NAME.tar.gz"
cat "dist/$NAME.tar.gz.sha256"
