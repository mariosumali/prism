#!/bin/bash
# build_pkg.sh — build PRISM release artifacts (§10):
#   dist/PRISM.dmg        PRISM.app with the camera extension embedded
#   dist/PRISM-Audio.pkg  the HAL AudioServerPlugIn, postinstall restarts
#                         coreaudiod (briefly interrupting ALL system audio)
#
# Prereqs: PRISM.xcodeproj generated (`xcodegen generate`) and TEAMID
# substituted (see README "Building from source"). Run Tools/notarize.sh
# on the outputs afterwards — unsigned/unnotarized components will not load.
#
# Licensed under the Apache License, Version 2.0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/PRISM.xcodeproj"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
CONFIGURATION="Release"
VERSION="${PRISM_VERSION:-1.0}"

echo "==> PRISM release build ($CONFIGURATION, version $VERSION)"

# ---------------------------------------------------------------- TEAMID ----
# Signing is the documented friction point of this project (§10). Catch the
# placeholder before wasting a build.
TEAMID_WARN=0
if grep -q "DEVELOPMENT_TEAM: TEAMID" "$ROOT/project.yml" 2>/dev/null; then
    TEAMID_WARN=1
    echo "!!  WARNING: project.yml still says 'DEVELOPMENT_TEAM: TEAMID'." >&2
fi
for ENT in "$ROOT/PRISM/PRISM.entitlements" \
           "$ROOT/PRISMCameraExtension/PRISMCameraExtension.entitlements"; do
    if grep -q "TEAMID" "$ENT" 2>/dev/null; then
        TEAMID_WARN=1
        echo "!!  WARNING: $(basename "$ENT") still contains the TEAMID placeholder." >&2
    fi
done
if [ "$TEAMID_WARN" -eq 1 ]; then
    cat >&2 <<'EOF'
!!
!!  Replace TEAMID with your Apple Developer Team ID in:
!!    * project.yml                                  (DEVELOPMENT_TEAM)
!!    * PRISM/PRISM.entitlements                     (app group)
!!    * PRISMCameraExtension/PRISMCameraExtension.entitlements (app group)
!!  then re-run `xcodegen generate`. Without a real Team ID the build will
!!  not sign, the system extension will refuse to load, and notarization
!!  will fail. Continuing anyway (useful for dry runs)...
!!
EOF
fi

if [ ! -d "$PROJECT" ]; then
    echo "ERROR: $PROJECT not found. Run 'xcodegen generate' first." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$DIST_DIR"

# ----------------------------------------------------------------- build ----
# Archive-less target builds into ./build (SYMROOT); the app target embeds
# and signs the camera extension as a dependency.
echo "==> xcodebuild: PRISM.app (+ embedded camera extension)"
xcodebuild -project "$PROJECT" -target PRISM \
           -configuration "$CONFIGURATION" SYMROOT="$BUILD_DIR" build

echo "==> xcodebuild: PRISM.driver (HAL AudioServerPlugIn)"
xcodebuild -project "$PROJECT" -target PRISMAudioPlugIn \
           -configuration "$CONFIGURATION" SYMROOT="$BUILD_DIR" build

APP="$BUILD_DIR/$CONFIGURATION/PRISM.app"
DRIVER="$BUILD_DIR/$CONFIGURATION/PRISM.driver"
[ -d "$APP" ]    || { echo "ERROR: $APP missing after build." >&2; exit 1; }
[ -d "$DRIVER" ] || { echo "ERROR: $DRIVER missing after build." >&2; exit 1; }

# -------------------------------------------------------- codesign check ----
# NOTE: --deep here is for VERIFICATION only. Never *sign* with --deep —
# xcodebuild has already signed each nested component (extension, app)
# individually with its own entitlements, which is the only correct way.
echo "==> codesign verification (--deep is verify-only; deep *signing* is wrong)"
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "!!  WARNING: PRISM.app failed codesign verification (placeholder TEAMID?)." >&2
fi
if ! codesign --verify --strict --verbose=2 "$DRIVER"; then
    echo "!!  WARNING: PRISM.driver failed codesign verification." >&2
fi

# ------------------------------------------------------------------- DMG ----
echo "==> Staging and creating dist/PRISM.dmg"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/PRISM.app"
ln -s /Applications "$STAGE/Applications"   # drag-to-install affordance
rm -f "$DIST_DIR/PRISM.dmg"
hdiutil create -volname "PRISM" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST_DIR/PRISM.dmg"

# ------------------------------------------------------------------- PKG ----
# Component pkg: root contains PRISM.driver, installed into the HAL plug-in
# directory; postinstall restarts coreaudiod so it loads the new driver.
echo "==> Building dist/PRISM-Audio.pkg"
PKGROOT="$BUILD_DIR/pkgroot"
SCRIPTS="$BUILD_DIR/pkgscripts"
rm -rf "$PKGROOT" "$SCRIPTS"
mkdir -p "$PKGROOT" "$SCRIPTS"
cp -R "$DRIVER" "$PKGROOT/PRISM.driver"

cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# PRISM-Audio.pkg postinstall — restart coreaudiod so it picks up the newly
# installed PRISM.driver. This briefly interrupts ALL system audio (§9);
# the installer UI warns the user before this runs.
launchctl kickstart -k system/com.apple.audio.coreaudiod || killall coreaudiod || true
exit 0
EOF
chmod 755 "$SCRIPTS/postinstall"

PKG_SIGN_ARGS=()
if [ -n "${PRISM_INSTALLER_IDENTITY:-}" ]; then
    # e.g. PRISM_INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
    PKG_SIGN_ARGS=(--sign "$PRISM_INSTALLER_IDENTITY")
else
    echo "!!  NOTE: PRISM_INSTALLER_IDENTITY not set — the .pkg will be unsigned." >&2
    echo "!!  Notarization requires a Developer ID Installer signature:" >&2
    echo "!!    PRISM_INSTALLER_IDENTITY='Developer ID Installer: You (TEAMID)' $0" >&2
fi

rm -f "$DIST_DIR/PRISM-Audio.pkg"
pkgbuild --root "$PKGROOT" \
         --install-location /Library/Audio/Plug-Ins/HAL \
         --scripts "$SCRIPTS" \
         --identifier horse.prism.PRISM.audio.pkg \
         --version "$VERSION" \
         "${PKG_SIGN_ARGS[@]+"${PKG_SIGN_ARGS[@]}"}" \
         "$DIST_DIR/PRISM-Audio.pkg"

echo ""
echo "==> Done."
echo "    $DIST_DIR/PRISM.dmg"
echo "    $DIST_DIR/PRISM-Audio.pkg"
echo "    Next: Tools/notarize.sh (both artifacts must be notarized to load)."
