#!/bin/sh
# Fetch the pinned VLCKit binaries into Vendor/ (git-ignored).
#
# VLCKit is VideoLAN's Objective-C wrapper around libVLC (LGPL 2.1). VideoLAN publishes it
# only as CocoaPods archives, not as a Swift package, so this script downloads the exact
# archives the official podspecs name, checks their SHA-256, and unpacks the xcframeworks.
# The Xcode project embeds Vendor/TVVLCKit.xcframework as a dynamic framework (SPEC §7).
#
# Pinned: TVVLCKit 3.7.4 (tvOS) and MobileVLCKit 3.7.4 (iOS, for the later iPhone app),
# both libVLC 3.0.24. Changing the version: update the URLs and checksums from the
# podspecs, and update docs/VLCKIT.md and THIRD_PARTY_NOTICES.md in the same commit.
#
# Usage: Tools/fetch-vlckit.sh [--ios]     (--ios also fetches MobileVLCKit)
set -eu

VERSION=3.7.4
TV_URL=https://download.videolan.org/cocoapods/prod/TVVLCKit-3.0-20260930-0854.tar.xz
TV_SHA=07892cae8e59e95a23f1fcf11692f802eae106312aa5ad9782faa2556b2d65d5
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

fetch TVVLCKit "$TV_URL" "$TV_SHA"
if [ "${1:-}" = "--ios" ]; then
    fetch MobileVLCKit "$IOS_URL" "$IOS_SHA"
fi
