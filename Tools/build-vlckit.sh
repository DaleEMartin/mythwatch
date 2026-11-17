#!/bin/sh
# Build TVVLCKit 3.7.4 from source without libzvbi, and install it in Vendor/ (git-ignored).
#
# Why: VideoLAN's prebuilt TVVLCKit 3.7.4 links zvbi 0.2.45, whose src/packet-830.c is GPL
# version 2 only (docs/VLCKIT.md §2). Mythwatch never uses zvbi (it decodes European Teletext;
# US recordings carry CEA-608 captions, which VLC's own `cc` decoder handles). This build is
# VideoLAN's own release build (`buildMobileVLCKit.sh -vft`, as their CI's TVVLCKit job runs it)
# with zvbi switched off in two places: the contrib libraries and VLC's configure. One more change:
# the framework's deployment target is raised from tvOS 10.2 to 15.0, the oldest Xcode 27 builds
# for (VideoLAN's CI uses Xcode 26; Mythwatch needs tvOS 26 anyway).
#
# It takes a long time (VLC builds its own tools and every contrib library from source) and needs
# only Xcode and the network: the VLCKit script puts its own tools first on PATH and ignores
# Homebrew. VLCKit's scripts and autotools break on paths with spaces, so the work tree is outside
# the repository: $MYTHWATCH_VLCKIT_WORK, default ~/Library/Caches/mythwatch-vlckit/<version>
# (a path without spaces). A second run reuses it.
#
# GNU make: macOS ships make 3.81, whose parallel jobs break when the ninja VLC builds for itself
# (Kitware's jobserver build) shares make's job pipe ("read jobs pipe: Resource temporarily
# unavailable"). VideoLAN's CI puts newer tools on VLC_PATH, so this script builds GNU make 4.4.1
# into the work area and does the same.
#
# Usage: Tools/build-vlckit.sh
set -eu

VERSION=3.7.4
COMMIT=54bba6d95502d0f3f7a9da581727935b21d55fb2   # VLCKit tag 3.7.4

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="${MYTHWATCH_VLCKIT_WORK:-$HOME/Library/Caches/mythwatch-vlckit}/$VERSION"
VENDOR="$ROOT/Vendor"
LOG="$WORK.log"
case "$WORK" in *" "*) echo "error: the work tree path must not contain spaces: $WORK" >&2; exit 1 ;; esac
mkdir -p "$(dirname "$WORK")" "$VENDOR"

# GNU make 4.4.1, checked against its published SHA-256.
MAKE_VERSION=4.4.1
MAKE_SHA=dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3
TOOLS="$(dirname "$WORK")/tools"
if [ ! -x "$TOOLS/bin/make" ]; then
    src="$(dirname "$WORK")/dl/make-$MAKE_VERSION.tar.gz"
    mkdir -p "$(dirname "$src")"
    [ -f "$src" ] || curl -fsSL --retry 3 -o "$src" "https://ftp.gnu.org/gnu/make/make-$MAKE_VERSION.tar.gz"
    [ "$(shasum -a 256 "$src" | cut -d' ' -f1)" = "$MAKE_SHA" ] || { echo "error: make checksum mismatch" >&2; exit 1; }
    tmp=$(mktemp -d)
    tar -xzf "$src" -C "$tmp"
    (cd "$tmp/make-$MAKE_VERSION" && ./configure --quiet --prefix="$TOOLS" --disable-nls && /usr/bin/make -s && /usr/bin/make -s install)
    rm -rf "$tmp"
fi
"$TOOLS/bin/make" --version | head -1
export VLC_PATH="$TOOLS/bin"

if [ ! -d "$WORK/.git" ]; then
    git clone --branch "$VERSION" https://code.videolan.org/videolan/VLCKit.git "$WORK"
fi
cd "$WORK"
[ "$(git rev-parse HEAD)" = "$COMMIT" ] || { echo "error: $WORK is not VLCKit $VERSION ($COMMIT)" >&2; exit 1; }

# Switch zvbi off. Each edit must match exactly once, so a changed script fails loudly here.
script=buildMobileVLCKit.sh
git checkout -- "$script"
# Fixed-string checks (grep -F), so they mean the same in any grep.
checkonce() {
    [ "$(grep -cF -- "$1" "$script")" = 1 ] || { echo "error: expected one line with: $1" >&2; exit 1; }
}
checkonce '        --enable-zvbi \'
checkonce 'SCARYFLAG="--enable-dvbpsi --enable-avcodec"'
checkonce '               IPHONEOS_DEPLOYMENT_TARGET=${SDK_MIN} \'
sed -i '' \
    -e 's/--enable-zvbi \\$/--disable-zvbi \\/' \
    -e 's/SCARYFLAG="--enable-dvbpsi --enable-avcodec"/SCARYFLAG="--enable-dvbpsi --enable-avcodec --disable-zvbi"/' \
    -e 's/^               IPHONEOS_DEPLOYMENT_TARGET=${SDK_MIN} \\$/               IPHONEOS_DEPLOYMENT_TARGET=${SDK_MIN} TVOS_DEPLOYMENT_TARGET=15.0 \\/' \
    "$script"
checkonce '        --disable-zvbi \'
checkonce 'SCARYFLAG="--enable-dvbpsi --enable-avcodec --disable-zvbi"'
checkonce 'IPHONEOS_DEPLOYMENT_TARGET=${SDK_MIN} TVOS_DEPLOYMENT_TARGET=15.0 \'
[ "$(grep -cF -- '--enable-zvbi' "$script")" = 0 ] || { echo "error: zvbi still enabled" >&2; exit 1; }

echo "Building TVVLCKit $VERSION without zvbi; log in $LOG"
./buildMobileVLCKit.sh -vft > "$LOG" 2>&1 || { echo "error: build failed; see $LOG" >&2; tail -30 "$LOG" >&2; exit 1; }

out="$WORK/build/TVVLCKit.xcframework"
[ -d "$out" ] || { echo "error: $out was not produced" >&2; exit 1; }

# Check every slice: no zvbi code, and VLC's own LGPL Teletext decoder is still there.
for bin in "$out"/*/TVVLCKit.framework/TVVLCKit; do
    if nm "$bin" | awk '{print $NF}' | grep -q -E '^_vbi_|vlc_entry__codec_libzvbi'; then
        echo "error: zvbi symbols remain in $bin" >&2
        exit 1
    fi
    nm "$bin" | grep -q vlc_entry__codec_telx || { echo "error: telx decoder missing from $bin" >&2; exit 1; }
done

rm -rf "$VENDOR/TVVLCKit.xcframework" "$VENDOR"/.TVVLCKit-*
cp -R "$out" "$VENDOR/"
cp COPYING "$VENDOR/TVVLCKit-COPYING.txt"
touch "$VENDOR/.TVVLCKit-$VERSION-nozvbi"
echo "TVVLCKit $VERSION without zvbi installed in Vendor/"
