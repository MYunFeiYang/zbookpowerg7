#!/bin/bash
# Build RtcRamRedirect.efi against edk2.
# Toolchain: XCODE5 (clang -> Mach-O MH_PRELOAD -> mtoc -> PE32+).
#
# mtoc is NOT shipped with edk2; a locally built copy lives in /usr/local/bin/mtoc
# (source: acidanthera/ocmtoc 1.0.4). tools_def.template hardcodes that path.
#
# Usage: ./build-rtcram.sh [DEBUG|RELEASE]
set -eo pipefail

BUILD_TYPE="${1:-RELEASE}"
EDK2="$HOME/src/edk2"
PKG="$HOME/src/RtcRamRedirectPkg"

if [ ! -x /usr/local/bin/mtoc ]; then
  echo "ERROR: /usr/local/bin/mtoc missing - build it from acidanthera/ocmtoc" >&2
  exit 1
fi

export WORKSPACE="$EDK2"
export PACKAGES_PATH="$EDK2:$HOME/src"
export EDK_TOOLS_PATH="$EDK2/BaseTools"
export CONF_PATH="$EDK2/Conf"
export PYTHON_COMMAND="${PYTHON_COMMAND:-python3}"

cd "$WORKSPACE"
# shellcheck disable=SC1091
source edksetup.sh BaseTools >/dev/null

build \
  -p "$PKG/RtcRamRedirectPkg.dsc" \
  -a X64 \
  -t XCODE5 \
  -b "$BUILD_TYPE" \
  -n "$(sysctl -n hw.ncpu)" \
  -D DISABLE_NEW_DEPRECATED_INTERFACES

OUT="$WORKSPACE/Build/RtcRamRedirectPkg/${BUILD_TYPE}_XCODE5/X64/RtcRamRedirect.efi"
if [ -f "$OUT" ]; then
  mkdir -p "$PKG/dist"
  cp -f "$OUT" "$PKG/dist/RtcRamRedirect.efi"
  echo "OK -> $PKG/dist/RtcRamRedirect.efi"
  ls -la "$PKG/dist/RtcRamRedirect.efi"
else
  echo "ERROR: build finished but $OUT is missing" >&2
  exit 1
fi
