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
    iOS6AIChat/Services/NSDataBase64.m \
    iOS6AIChat/Services/Logger.m \
    iOS6AIChat/Views/ChatBubbleView.m \
    iOS6AIChat/Views/ChatMessageCell.m \
    iOS6AIChat/Views/ComposerView.m \
    iOS6AIChat/Views/IconDrawing.m \
    iOS6AIChat/Controllers/ChatViewController.m \
    iOS6AIChat/Controllers/HistoryViewController.m \
    iOS6AIChat/Controllers/SettingsViewController.m \
    iOS6AIChat/Controllers/ManagementViewController.m \
    iOS6AIChat/Controllers/ModelManagementViewController.m \
    iOS6AIChat/Controllers/CharacterManagementViewController.m \
    iOS6AIChat/Controllers/LogViewController.m \
    iOS6AIChat/Controllers/DrawerViewController.m

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
# -fno-objc-exceptions     — DISABLE @try/@catch (v261024-19: cctools-port armv7 .ARM.exidx tables are unreliable; v17 wave of @try caused SIGSEGV at function entry, NOT NSException => no log captured). Compiler refuses to emit exception tables.
# -fobjc-legacy-dispatch   → legacy objc_msgSend for iOS 6 ABI compatibility
# -Wno-deprecated          → silence iOS-6-era API deprecation warnings
# -Wno-error=implicit-function-declaration → don't fail on missing prototypes
# -I flags below: headers are imported by bare name (#import "Foo.h"),
# so each subdirectory that contains .h files must be on the include path.
iOS6AIChat_CFLAGS  = -fno-objc-arc -fobjc-legacy-dispatch -fno-objc-exceptions \
	             -Wno-deprecated -Wno-error=implicit-function-declaration \
	             -Wno-error=unused-variable -Wno-unused-variable \
	             -std=gnu99 \
	             -IiOS6AIChat -IiOS6AIChat/Models -IiOS6AIChat/Services \
	             -IiOS6AIChat/Views -IiOS6AIChat/Controllers -IiOS6AIChat/Resources
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
    # Modern Theos master doesn't auto-include rules.mk OR the type
    # dispatcher (application.mk) at the top level — without these,
    # `make all` ends up empty ("Nothing to be done for 'all'"). The
    # canonical Theos entry point is `application.mk`, which dispatches
    # to master/application.mk (top-level) or instance/application.mk
    # (recursive make when THEOS_CURRENT_INSTANCE is set).
    include $(THEOS)/makefiles/rules.mk
    include $(THEOS)/makefiles/application.mk
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
# The .app is inside the staged .deb payload at .theos/_/Applications/
# (for rootful scheme) or .theos/_/var/jb/Applications/ (for rootless).
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
	APP=Payload/iOS6AIChat.app; \
	echo "==> Ensuring Info.plist is in the bundle (Theos sometimes forgets it)"; \
	if [ ! -f "$$APP/Info.plist" ]; then \
	    cp iOS6AIChat/Resources/iOS6AIChat-Info.plist "$$APP/Info.plist"; \
	fi; \
	echo "==> Copying app icons into the bundle root"; \
	for icon in Icon.png Icon@2x.png Icon-72.png Icon-72@2x.png lightbulb.png camera.png send.png; do \
	    if [ -f "iOS6AIChat/Resources/Icons/$$icon" ] && [ ! -f "$$APP/$$icon" ]; then \
	        cp "iOS6AIChat/Resources/Icons/$$icon" "$$APP/$$icon"; \
	    fi; \
	done; \
	echo "==> Converting Info.plist to binary format (iOS 6 prefers binary)"; \
	if command -v plutil >/dev/null 2>&1; then \
	    plutil -convert binary1 "$$APP/Info.plist" 2>/dev/null || true; \
	fi; \
	echo "==> Ad-hoc re-signing binary with ldid (ensures it loads on jailbroken iOS)"; \
	if command -v ldid >/dev/null 2>&1; then \
	    ldid -S "$$APP/iOS6AIChat" 2>/dev/null || true; \
	fi; \
	echo "==> Final .app contents:"; \
	ls -la "$$APP"; \
	echo "==> Zipping into iOS6AIChat-unsigned.ipa"; \
	zip -r -X iOS6AIChat-unsigned.ipa Payload >/dev/null; \
	echo "==> Built iOS6AIChat-unsigned.ipa"; \
	ls -la iOS6AIChat-unsigned.ipa

show-app: package
	@find .theos/_ -name "iOS6AIChat.app" -type d -print -quit

clean-ipa:
	rm -rf Payload iOS6AIChat-unsigned.ipa
