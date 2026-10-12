#!/usr/bin/env bash
#
# build-ipa.sh — one-shot wrapper that builds the Theos-based Docker
# image and runs it against the local source tree to produce:
#
#     packages/iOS6AIChat_<ver>_iphoneos-arm.deb
#     iOS6AIChat-unsigned.ipa
#
# Prereqs:
#   * Docker (or Podman) installed and running
#   * This script invoked from the iOS6AIChat/ project root
#
# Usage:
#   ./build-ipa.sh              # first run: builds the image, then runs it
#   ./build-ipa.sh --no-build   # skips image build, just runs the container
#   ./build-ipa.sh --clean      # removes the local image first, then builds
#
# What it does:
#   1. Builds a Docker image tagged "ios6theos" from ./Dockerfile.
#   2. Runs that image with the current directory mounted at /work.
#   3. The container invokes `make clean && make package && make ipa`,
#      which leaves the .deb and .ipa artifacts in the current dir.
#
# First build: ~5–10 minutes (downloading cctools-port + iPhoneOS6.0.sdk).
# Subsequent runs are instant (image is cached).

set -euo pipefail

IMAGE_TAG="ios6theos:latest"
DOCKER="${CONTAINER_ENGINE:-docker}"

# --- Arg parsing ---------------------------------------------------------
DO_BUILD=1
DO_CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --clean)    DO_CLEAN=1  ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

# --- Sanity checks -------------------------------------------------------
if ! command -v "$DOCKER" >/dev/null 2>&1; then
    echo "❌ $DOCKER not found in PATH."
    echo "   Install Docker (https://docs.docker.com/get-docker/) or"
    echo "   set CONTAINER_ENGINE=podman to use Podman instead."
    exit 1
fi

if [ ! -f Makefile ] || [ ! -f control ]; then
    echo "❌ This script must be run from the iOS6AIChat/ project root"
    echo "   (where Makefile and control live)."
    pwd
    exit 1
fi

# --- Clean image if requested -------------------------------------------
if [ "$DO_CLEAN" = 1 ]; then
    echo "==> Removing existing image $IMAGE_TAG"
    "$DOCKER" rmi -f "$IMAGE_TAG" 2>/dev/null || true
fi

# --- Build image ---------------------------------------------------------
if [ "$DO_BUILD" = 1 ]; then
    echo "==> Building Docker image $IMAGE_TAG"
    echo "    (first build takes 5-10 min; subsequent builds are cached)"
    "$DOCKER" build \
        --tag "$IMAGE_TAG" \
        --file Dockerfile \
        .
fi

# --- Run container against local source ---------------------------------
echo "==> Running $IMAGE_TAG against $PWD"
mkdir -p packages
"$DOCKER" run \
    --rm \
    --tty \
    --interactive \
    --volume "$PWD:/work" \
    --workdir /work \
    "$IMAGE_TAG"

echo ""
echo "==> Done. Artifacts:"
ls -la packages/*.deb iOS6AIChat-unsigned.ipa 2>&1 || true
