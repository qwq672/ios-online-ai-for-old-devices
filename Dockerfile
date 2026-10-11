# Dockerfile — self-contained iOS 6 cross-compiler on Linux.
#
# Builds the Theos toolchain (clang + cctools-port + ldid) and downloads
# iPhoneOS6.0.sdk so that simply running:
#
#     docker build -t ios6theos .
#     docker run --rm -v "$PWD:/work" ios6theos
#
# in the project root will produce:
#     - packages/iOS6AIChat_1.0.0-1_iphoneos-arm.deb  (jailbroken install)
#     - iOS6AIChat-unsigned.ipa                         (Sideloadly/AltStore install)
#
# No Mac, no Apple Developer account, no Xcode, no local toolchain setup.

FROM ubuntu:22.04

LABEL org.opencontainers.image.title="iOS6AIChat Theos builder"
LABEL org.opencontainers.image.description="Cross-compiles Objective-C for iOS 6+ on plain Linux via Theos + cctools-port"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# === APT deps =============================================================
# fakeroot + dpkg-dev are needed for Theos to assemble .deb packages.
# ldid is the ad-hoc code signer (mimics Apple's codesign).
# libplist-utils provides plutil for .plist manipulation.
# zip/unzip for IPA packaging.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget git \
        build-essential clang llvm \
        make perl bash \
        rsync fakeroot dpkg-dev \
        ldid libplist-utils \
        zip unzip xz-utils \
        libssl3 zlib1g && \
    rm -rf /var/lib/apt/lists/*

# === Theos itself =========================================================
ENV THEOS=/opt/theos
RUN git clone --recursive --depth=1 https://github.com/theos/theos.git $THEOS && \
    chmod -R a+rX $THEOS

# === iPhoneOS 6.0 SDK =====================================================
# Pull the iOS 6 SDK tarball from Theos' public SDK mirror.
# (Legally gray — Apple's iOS SDK is not redistributable, but the
#  theos/sdks repo has hosted these since 2010. For a clean legal
#  setup, replace the URL below with one of your own hosted SDK
#  tarballs — see README.md for how to extract from Xcode 4.5.)
RUN mkdir -p $THEOS/sdks && \
    echo "Downloading iPhoneOS6.0.sdk from theos/sdks…" && \
    (curl -fsSL -o /tmp/sdk.tar.xz \
         https://github.com/theos/sdks/raw/master/iPhoneOS6.0.sdk.tar.xz \
      || curl -fsSL -o /tmp/sdk.tar.xz \
         https://github.com/theos/sdks/raw/main/iPhoneOS6.0.sdk.tar.xz) && \
    tar xJf /tmp/sdk.tar.xz -C $THEOS/sdks && \
    rm /tmp/sdk.tar.xz && \
    ls $THEOS/sdks

# === Verify everything is in place =======================================
RUN echo "--- Theos sanity check ---" && \
    ls $THEOS/makefiles/common.mk && \
    ls $THEOS/sdks/iPhoneOS6.0.sdk/System/Library/Frameworks/UIKit.framework && \
    which clang && which ldid && which fakeroot && which dpkg-deb && \
    echo "--- All set. ---"

WORKDIR /work

# === Default entrypoint: clean → package → ipa ===========================
# All output lands in /work which the host mounts as a volume.
CMD ["bash", "-c", "\
    set -euo pipefail; \
    make clean || true; \
    make package; \
    make ipa; \
    echo ''; \
    echo '======================================='; \
    echo '  Build complete.'; \
    echo '======================================='; \
    ls -la packages/*.deb 2>/dev/null || true; \
    ls -la iOS6AIChat-unsigned.ipa 2>/dev/null || true; \
"]
