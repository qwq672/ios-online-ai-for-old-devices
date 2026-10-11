# Makefile — Theos build for cross-compiling iOS 6+ apps on Linux.
#
# Why this exists:
#   GitHub's macos-* runners cannot deploy to iOS 6 (Xcode 14+ dropped
#   iOS <=10 SDKs). Theos is the jailbreak-community toolchain that runs
#   on plain Linux + clang + cctools-port, and can target iOS 6 with
#   the iPhoneOS6.0.sdk that ships with Xcode 4.5.
#
# Outputs:
#   packages/iOS6AIChat_<ver>_iphoneos-arm.deb   — install via Cydia/Sileo
#   iOS6AIChat-unsigned.ipa                       — pack via `make ipa`,
#                                                   install via Sideloadly/AltStore
#
# Quick start on a Linux box:
#   1. Install deps:
#        sudo apt install clang make perl rsync fakeroot dpkg-dev ldid
#   2. Install Theos:
#        git clone --recursive https://github.com/theos/theos ~/theos
#        export THEOS=~/theos
#   3. Drop iPhoneOS6.0.sdk into $THEOS/sdks/
#        wget https://github.com/theos/sdks/raw/master/iPhoneOS6.0.sdk.tar.xz
#        tar xf iPhoneOS6.0.sdk.tar.xz -C $THEOS/sdks
#   4. Build:
#        make package            # → packages/*.deb
#        make ipa                 # → iOS6AIChat-unsigned.ipa (alongside .deb)
#
# Env-var overrides:
#   TARGET = iphone:clang:6.0:6.0   (deployment : sdk)
#   ARCHS  = armv7 armv7s            (32-bit only; iOS 6 era devices)

# === Build target =========================================================
# Theos syntax: iphone:<toolchain>:<deployment>:<sdk-version>
TARGET := iphone:clang:6.0:6.0
# Fallback: if only newer SDK is installed locally, override at call time:
#   make TARGET=iphone:clang:6.0:9.0  → still deploys to iOS 6, but uses
#   iPhoneOS9.0.sdk at build time (binary may use iOS 9+ APIs if any leak in).

# === Architectures ========================================================
# iOS 6 devices are 32-bit ARM only (iPhone 3GS / 4 / 4S / 5 / iPad 1-3).
# armv7s adds the A6 (iPhone 5) specific optimisations; armv7 is universal.
ARCHS = armv7 armv7s

# === App identity =========================================================
APPLICATION_NAME = iOS6AIChat

# === Sources (relative to project root) ==================================
# Each .m explicitly listed so there's no glob ambiguity on Linux make.
iOS6AIChat_FILES = \
    iOS6AIChat/main.m \
    iOS6AIChat/AppDelegate.m \
    iOS6AIChat/iOS6Theme.m \
    iOS6AIChat/Models/Message.m \
    iOS6AIChat/Models/Conversation.m \
    iOS6AIChat/Services/ConversationStore.m \
    iOS6AIChat/Services/NetworkService.m \
    iOS6AIChat/Services/MarkdownParser.m \
    iOS6AIChat/Views/ChatBubbleView.m \
    iOS6AIChat/Views/ChatMessageCell.m \
    iOS6AIChat/Views/ComposerView.m \
    iOS6AIChat/Controllers/ChatViewController.m \
    iOS6AIChat/Controllers/HistoryViewController.m \
    iOS6AIChat/Controllers/SettingsViewController.m

# === Info.plist (source — Theos merges in standard fields) ===============
iOS6AIChat_INFOPLIST_FILE = iOS6AIChat/Resources/iOS6AIChat-Info.plist

# === Prefix header =========================================================
# Reuse the same PCH we use for Xcode builds. Theos auto-includes it in
# every .m via the *_PREFIX_HEADER variable.
iOS6AIChat_PREFIX_HEADER = iOS6AIChat/iOS6AIChat-Prefix.pch

# === Frameworks ==========================================================
iOS6AIChat_FRAMEWORKS = UIKit Foundation CoreGraphics

# === Compiler flags ======================================================
# This codebase is MRC (manual reference counting), NOT ARC.
# -fno-objc-arc            → disable ARC for these sources
# -fobjc-exceptions        → enable @try/@catch (we don't use it, but safe)
# -fobjc-legacy-dispatch   → legacy objc_msgSend for iOS 6 ABI compatibility
# -Wno-deprecated          → silence iOS-6-era API deprecation warnings
# -Wno-error=implicit-function-declaration → don't fail on missing prototypes
iOS6AIChat_CFLAGS  = -fno-objc-arc -fobjc-exceptions -fobjc-legacy-dispatch \
		     -Wno-deprecated -Wno-error=implicit-function-declaration \
		     -std=gnu99
iOS6AIChat_LDFLAGS = -framework UIKit -framework Foundation -framework CoreGraphics

# === Packaging ===========================================================
# Theos package scheme — modern Theos master supports 'rootless' for
# modern jailbreaks (palera1n, Dopamine). For iOS 6 rootful jailbreaks
# the .deb format is the same; rootless installs to /var/jb/Applications
# but on a rootful jailbreak that path doesn't exist, so use rootless
# scheme + override INSTALL_PATH below.
# To force rootful scheme on older Theos versions, set:
#   make THEOS_PACKAGE_SCHEME=rootful
THEOS_PACKAGE_SCHEME = rootless

# Install the .app under /Applications (becomes a system app on jailbreak).
# On rootless jailbreaks this is /var/jb/Applications; on rootful iOS 6
# jailbreaks (evasi0n etc.) this is /Applications directly.
INSTALL_PATH = /Applications

# Lean packaging strips debug symbols; smaller .deb.
THEOS_LEAN_PACKAGE = 1

# === Theos bootstrap =====================================================
ifneq ($(THEOS),)
    include $(THEOS)/makefiles/common.mk
    # Modern Theos master doesn't auto-include rules.mk at the top level,
    # which means master/application.mk never gets loaded and `make all`
    # ends up empty ("Nothing to be done for 'all'"). Explicitly include
    # rules.mk AND master/application.mk here so the real `all::` target
    # + application instance machinery is registered.
    include $(THEOS)/makefiles/rules.mk
    include $(THEOS)/makefiles/master/application.mk
else
    $(error "THEOS env var not set. Install Theos: https://theos.dev/docs/installation-linux")
endif

# === Convenience targets =================================================

# Local clean target — adds to Theos' built-in `clean` (note the double
# colon `::`, which is Make's "add to existing rule" syntax vs. single
# colon `:` which would conflict if Theos also defined `clean:`).
.PHONY: clean
clean::
	rm -rf .theos obj build packages Payload *.deb iOS6AIChat-unsigned.ipa

# Pack an unsigned .ipa from the .app Theos just produced.
# The .app is inside the staged .deb payload at .theos/_/Applications/.
.PHONY: ipa clean-ipa show-app
ipa: package
	@echo "==> Locating staged .app bundle in .theos/_/"
	@BUILT_APP=$$(find .theos/_ -name "iOS6AIChat.app" -type d 2>/dev/null | head -1); \
	if [ -z "$$BUILT_APP" ]; then \
	    echo "Could not find iOS6AIChat.app — did 'make package' succeed?"; exit 1; \
	fi; \
	echo "==> Found $$BUILT_APP"; \
	rm -rf Payload iOS6AIChat-unsigned.ipa; \
	mkdir Payload; \
	cp -R "$$BUILT_APP" Payload/; \
	zip -r -X iOS6AIChat-unsigned.ipa Payload >/dev/null; \
	echo "==> Built iOS6AIChat-unsigned.ipa"

show-app: package
	@find .theos/_ -name "iOS6AIChat.app" -type d -print -quit

clean-ipa:
	rm -rf Payload iOS6AIChat-unsigned.ipa
