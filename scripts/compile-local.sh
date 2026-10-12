#!/usr/bin/env bash
#
# compile-local.sh — Cross-compile the iOS6AIChat sources on Linux without
# Mac/Theos. Uses clang + lld (ld64.lld) + ldid, all available on plain Linux.
#
# Produces an unsigned .ipa at the project root.

set -euo pipefail

# --- Paths ---------------------------------------------------------------
PROJ=/home/z/my-project/download/iOS6AIChat
SDK=${SDK:-$HOME/theos-toolchain/sdks/iPhoneOS6.0.sdk}
LLVM=$HOME/local-debs/extracted/usr/lib/llvm-19/bin
CLANG=$LLVM/clang
LD64=$LLVM/ld64.lld
LDID=$HOME/theos-toolchain/sb-ldid/ldid
LD_LIBRARY_PATH=$HOME/local-debs/extracted/usr/lib/x86_64-linux-gnu:$HOME/theos-toolchain/extracted-debs/usr/lib/x86_64-linux-gnu
export LD_LIBRARY_PATH

# iOS 6 cross-compile flags.
# Default arm64 + iOS 11.0 because Debian's lld-19 ld64 backend doesn't
# support 32-bit ARM Mach-O. For a true armv7 / iOS 6 binary, use the
# Docker path documented in README.md (Theos + cctools-port).
ARCH=${ARCH:-arm64}
DEPLOY=${DEPLOY:-11.0}
SYSROOT=$SDK
TARGET_TRIPLE="${ARCH}-apple-darwin11"
MIN_VERSION_FLAG="-miphoneos-version-min=${DEPLOY}"

# C / ObjC compiler flags.
CFLAGS=(
    -target "$TARGET_TRIPLE"
    $MIN_VERSION_FLAG
    -isysroot "$SYSROOT"
    -fno-objc-arc
    -fobjc-exceptions
    -fobjc-legacy-dispatch
    -fcolor-diagnostics
    -Wno-deprecated
    -Wno-error=implicit-function-declaration
    -std=gnu99
    -I"$PROJ/iOS6AIChat"
    -I"$PROJ/iOS6AIChat/Models"
    -I"$PROJ/iOS6AIChat/Services"
    -I"$PROJ/iOS6AIChat/Views"
    -I"$PROJ/iOS6AIChat/Controllers"
)

# --- Build .o files -----------------------------------------------------
BUILD_DIR="$PROJ/build-local"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/obj"

SRC_ROOT="$PROJ/iOS6AIChat"
SOURCES=(
    "$SRC_ROOT/main.m"
    "$SRC_ROOT/AppDelegate.m"
    "$SRC_ROOT/iOS6Theme.m"
    "$SRC_ROOT/Models/Message.m"
    "$SRC_ROOT/Models/Conversation.m"
    "$SRC_ROOT/Services/ConversationStore.m"
    "$SRC_ROOT/Services/NetworkService.m"
    "$SRC_ROOT/Services/MarkdownParser.m"
    "$SRC_ROOT/Views/ChatBubbleView.m"
    "$SRC_ROOT/Views/ChatMessageCell.m"
    "$SRC_ROOT/Views/ComposerView.m"
    "$SRC_ROOT/Controllers/ChatViewController.m"
    "$SRC_ROOT/Controllers/HistoryViewController.m"
    "$SRC_ROOT/Controllers/SettingsViewController.m"
)

echo "==> Compiling ${#SOURCES[@]} source files for ${ARCH} iOS ${DEPLOY}+"
for src in "${SOURCES[@]}"; do
    rel="${src#$SRC_ROOT/}"
    out="$BUILD_DIR/obj/${rel%.m}.o"
    mkdir -p "$(dirname "$out")"
    echo "  CC  $rel"
    $CLANG "${CFLAGS[@]}" -c "$src" -o "$out"
done

# --- Link .app binary ----------------------------------------------------
APP_BUNDLE="$BUILD_DIR/iOS6AIChat.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE"

echo "==> Linking iOS6AIChat (Mach-O / $ARCH)"
# ld64.lld (LLVM's Mach-O linker) — Apple-style argument syntax.
# The .tbd files in modern iPhoneOS*.sdk frameworks are text-based
# dylib stubs; ld64.lld resolves them when given the framework name
# via -framework + the syslibroot search path.
$LD64 \
    -arch "$ARCH" \
    -platform_version ios "$DEPLOY" "$DEPLOY" \
    -syslibroot "$SYSROOT" \
    -F "$SYSROOT/System/Library/Frameworks" \
    -L "$SYSROOT/usr/lib" \
    -execute \
    -o "$APP_BUNDLE/iOS6AIChat" \
    -ObjC \
    -framework UIKit \
    -framework Foundation \
    -framework CoreGraphics \
    -framework QuartzCore \
    -lSystem \
    $(find "$BUILD_DIR/obj" -name '*.o' | sort) 2>&1 | tail -30

# --- Bundle resources ----------------------------------------------------
echo "==> Copying Info.plist"
cp "$PROJ/iOS6AIChat/Resources/iOS6AIChat-Info.plist" "$APP_BUNDLE/Info.plist"

# --- Ad-hoc sign with ldid ----------------------------------------------
echo "==> Ad-hoc signing binary with ldid"
$LDID -S "$APP_BUNDLE/iOS6AIChat" 2>&1 | tail -3 || true

# --- Pack .ipa -----------------------------------------------------------
echo "==> Packing .ipa"
cd "$BUILD_DIR"
mkdir Payload
cp -R "iOS6AIChat.app" Payload/
zip -r -X "$PROJ/iOS6AIChat-unsigned.ipa" Payload >/dev/null
echo "==> Done: $PROJ/iOS6AIChat-unsigned.ipa"
ls -la "$PROJ/iOS6AIChat-unsigned.ipa"
file "$APP_BUNDLE/iOS6AIChat"
