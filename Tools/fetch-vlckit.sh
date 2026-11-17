#!/bin/sh
# Fetch VideoLAN's prebuilt MobileVLCKit into Vendor/ (git-ignored), for the later iPhone app.
#
# The tvOS app no longer uses a prebuilt VLCKit: Tools/build-vlckit.sh builds TVVLCKit from
# source without libzvbi (docs/VLCKIT.md §1). This prebuilt MobileVLCKit still contains zvbi's
# GPL-2-only code; build it from source the same way before any iPhone release.
#
# VideoLAN publishes VLCKit only as CocoaPods archives, not as a Swift package, so this script
# downloads the exact archive the official podspec names, checks its SHA-256, and unpacks the
# xcframework. Pinned: MobileVLCKit 3.7.4 (libVLC 3.0.24).
#
# Usage: Tools/fetch-vlckit.sh
set -eu

VERSION=3.7.4
IOS_URL=https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz
IOS_SHA=c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENDOR="$ROOT/Vendor"
mkdir -p "$VENDOR"

# fetch NAME URL SHA
fetch() {
    name=$1 url=$2 sha=$3
    stamp="$VENDOR/.$name-$VERSION"
    if [ -f "$stamp" ] && [ -d "$VENDOR/$name.xcframework" ]; then
        echo "$name $VERSION already present"
        return
    fi
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    echo "Downloading $name $VERSION"
    curl -fsSL --retry 3 -o "$work/archive.tar.xz" "$url"
    actual=$(shasum -a 256 "$work/archive.tar.xz" | cut -d' ' -f1)
    if [ "$actual" != "$sha" ]; then
        echo "error: $name checksum mismatch: expected $sha, got $actual" >&2
        exit 1
    fi
    mkdir "$work/x"
    tar -xJf "$work/archive.tar.xz" -C "$work/x"
    rm -rf "$VENDOR/$name.xcframework" "$VENDOR/$name-COPYING.txt"
    mv "$work/x/$name-binary/$name.xcframework" "$VENDOR/"
    mv "$work/x/$name-binary/COPYING.txt" "$VENDOR/$name-COPYING.txt"
    rm -f "$VENDOR/.$name-"*
    touch "$stamp"
    rm -rf "$work"
    trap - EXIT
    echo "$name $VERSION installed in Vendor/"
}

fetch MobileVLCKit "$IOS_URL" "$IOS_SHA"
