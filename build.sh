#!/bin/zsh
# Builds Fire.app (Release, arm64 + x86_64 optional) and places it in ./build/Fire.app
#
# Usage:  ./build.sh            # build for this Mac's architecture
#         ./build.sh --universal  # arm64 + x86_64
#         ./build.sh --install    # additionally copy to ~/Applications
#
# The app is signed ad hoc (no Apple Developer account needed).
set -e
cd "${0:A:h}"

ARCHS_ARG="$(uname -m)"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS_ARG="arm64 x86_64" ;;
    --install) INSTALL=1 ;;
  esac
done

mkdir -p build
xcodebuild \
  -project Ice.xcodeproj \
  -scheme Ice \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -skipMacroValidation -skipPackagePluginValidation \
  ARCHS="$ARCHS_ARG" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build > build/xcodebuild.log 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/xcodebuild.log | cut -c1-240 | sort -u | head -15
grep -q "BUILD SUCCEEDED" build/xcodebuild.log || { echo "Build failed, see build/xcodebuild.log"; exit 1; }

APP="build/DerivedData/Build/Products/Release/Fire.app"
rm -rf build/Fire.app
cp -R "$APP" build/Fire.app
codesign --force --deep --sign - --options runtime build/Fire.app
codesign --verify --deep --strict build/Fire.app && echo "Built: $PWD/build/Fire.app"

if [ "$INSTALL" = "1" ]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Fire.app
  cp -R build/Fire.app ~/Applications/Fire.app
  echo "Installed: ~/Applications/Fire.app"
fi
