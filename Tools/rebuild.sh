#!/bin/bash
# rebuild.sh — build the current branch and (re)install it to /Applications.
#
#   Tools/rebuild.sh
#
# Regenerates the Xcode project, builds the PRISM scheme (Release), then
# updates /Applications/PRISM.app in place and launches it. Keeping the bundle
# and executable inodes stable matters on macOS 26: Control Center includes
# them in its remembered status-item identity, so replacing the whole bundle
# can strand a perfectly valid menu item off-screen after every rebuild. The
# prior build is still kept as PRISM.app.previous for rollback.
#
# Licensed under the Apache License, Version 2.0.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=PRISM.xcodeproj
SCHEME=PRISM
# The app installed by the front-door rebuild is the app the user actually
# runs, so it must be the optimized build. `Tools/run_local.sh` remains the
# fast Debug path for debugger sessions. The environment override is useful
# when diagnosing an installed build without quietly making every normal run
# pay Debug's substantial CPU and memory cost.
CONFIG="${PRISM_BUILD_CONFIGURATION:-Release}"
case "$CONFIG" in
    Debug|Release) ;;
    *) echo "rebuild.sh: PRISM_BUILD_CONFIGURATION must be Debug or Release" >&2; exit 2 ;;
esac
INSTALLED=/Applications/PRISM.app
# Deliberately NOT named "*.app": it is a rollback payload, not a launchable
# copy. Some Launch Services versions inspect its Info.plist anyway, so the
# installer explicitly unregisters it below.
PREVIOUS=/Applications/PRISM.app.previous
PREVIOUS_INFO="$PREVIOUS/Contents/Info.plist"
PREVIOUS_INFO_DISABLED="$PREVIOUS/Contents/Info.plist.rollback"
LOG="${TMPDIR:-/tmp}/prism-build.log"

active_extension_build() {
    systemextensionsctl list 2>/dev/null \
        | sed -nE '/^\*.*horse\.prism\.PRISM\.camera/ s@.*\([^/]*/([^)]*)\).*@\1@p' \
        | head -1
}

extension_restart_pending() {
    systemextensionsctl list 2>/dev/null \
        | grep -F 'horse.prism.PRISM.camera' \
        | grep -Fq '[terminated waiting to uninstall on reboot]'
}

warn_extension_restart() {
    echo >&2
    echo "    ⚠  macOS installed the new PRISM Camera but needs one restart" >&2
    echo "       to retire the old camera extension and load the new one." >&2
}

# macOS decides whether an already-approved system extension needs replacing
# from CFBundleVersion, not from the executable's code hash. A fixed build
# number can therefore leave an older camera extension running indefinitely
# even though the freshly installed app embeds a different binary. Derive a
# stable numeric version from the newest extension-contract source: editing
# the extension bumps it, while rebuilding unchanged sources does not create
# a pointless replacement request.
EXTENSION_BUILD=1
while IFS= read -r source_file; do
    source_mtime=$(stat -f '%m' "$source_file")
    if [ "$source_mtime" -gt "$EXTENSION_BUILD" ]; then
        EXTENSION_BUILD=$source_mtime
    fi
done < <(find PRISMCameraExtension PRISMShared -type f -print; printf '%s\n' project.yml)
ACTIVE_EXTENSION_BEFORE=$(active_extension_build || true)

# Always regenerate. project.yml lists sources as directories ("- path: PRISM"),
# so xcodegen enumerates the file tree when it runs: adding or deleting any
# source file changes the project even though project.yml itself did not. The
# old "regenerate only if project.yml is newer than project.pbxproj" test
# therefore built happily against a stale project, silently leaving new files
# out of the app and out of the test target. Generation costs ~0.1s; there was
# never anything to save by skipping it.
echo "==> generating project (xcodegen)"
xcodegen generate >/dev/null

# Warnings are kept out of the terminal and put in a log: this build emits
# dozens, and a real error scrolling past inside them is how a failed build
# gets mistaken for a successful one.
echo "==> building $SCHEME ($CONFIG)"
echo "    camera extension build $EXTENSION_BUILD"
status=0
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    CURRENT_PROJECT_VERSION="$EXTENSION_BUILD" \
    -quiet build >"$LOG" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "==> BUILD FAILED — nothing was installed, $INSTALLED is untouched" >&2
    echo >&2
    grep -E 'error:|\*\* BUILD FAILED' "$LOG" | head -40 >&2 || true
    echo >&2
    echo "    full log: $LOG" >&2
    exit "$status"
fi

# grep -c prints "0" AND exits 1 when there is no match, so the usual
# "|| echo 0" fallback would print a second zero. Take the count, then
# default it only if grep produced nothing at all.
warnings=$(grep -c "warning:" "$LOG" 2>/dev/null || true)
[ -n "$warnings" ] || warnings=0
if [ "$warnings" -eq 0 ]; then
    # Zero is also what an incremental build reports when nothing recompiled,
    # so do not let it read as "the warnings were fixed".
    echo "    ok — nothing new compiled, or no warnings (log: $LOG)"
else
    echo "    ok — $warnings warnings (log: $LOG)"
fi

# Ask xcodebuild where the product landed instead of hardcoding the
# DerivedData hash (it changes if the checkout ever moves).
APP=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ CODESIGNING_FOLDER_PATH =/{print $2; exit}')
[ -d "$APP" ] || { echo "rebuild.sh: built app not found at '$APP'" >&2; exit 1; }

# Do not stop or touch the working install unless the product itself is a
# complete, correctly signed app bundle.
codesign --verify --deep --strict "$APP"

if pgrep -x PRISM >/dev/null 2>&1; then
    echo "==> stopping the running PRISM"
    pkill -x PRISM || true
    sleep 1
fi

# Back up exactly one generation, then update the live bundle in place. rsync's
# --inplace is intentional: it preserves the executable inode as well as the
# outer bundle inode, keeping Control Center's status-item identity stable.
echo "==> installing to /Applications"
had_installed=0
if [ -d "$INSTALLED" ]; then
    had_installed=1
    rm -rf "$PREVIOUS"
    ditto "$INSTALLED" "$PREVIOUS"
    # A backup containing Contents/Info.plist is still discoverable as an app
    # even without a .app suffix. Hide that one file until rollback so there
    # cannot be a second PRISM registration between rebuilds.
    mv "$PREVIOUS_INFO" "$PREVIOUS_INFO_DISABLED"
fi

if [ "$had_installed" -eq 1 ]; then
    install_command=(rsync -a --delete --inplace "$APP/" "$INSTALLED/")
else
    install_command=(ditto "$APP" "$INSTALLED")
fi

if ! "${install_command[@]}" || ! codesign --verify --deep --strict "$INSTALLED"; then
    echo "rebuild.sh: install failed; restoring the previous build" >&2
    if [ "$had_installed" -eq 1 ] && [ -d "$PREVIOUS" ]; then
        mv "$PREVIOUS_INFO_DISABLED" "$PREVIOUS_INFO"
        rsync -a --delete --inplace "$PREVIOUS/" "$INSTALLED/" || true
        mv "$PREVIOUS_INFO" "$PREVIOUS_INFO_DISABLED"
    else
        rm -rf "$INSTALLED"
    fi
    exit 1
fi

# xcodebuild products and old local copies must not compete with the installed
# bundle in Launch Services. The app in /Applications is the sole canonical
# registration.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
    # Registering the canonical app can make Launch Services rescan its
    # siblings, so unregister rollback/legacy copies after that scan.
    "$LSREGISTER" -u "$PREVIOUS" >/dev/null 2>&1 || true
    "$LSREGISTER" -u /Applications/PRISM.app.backup >/dev/null 2>&1 || true
fi

echo "==> launching"
open "$INSTALLED"

# `open` asks Launch Services to resolve the bundle and can trigger one more
# sibling scan. Clean those rollback records after the launch request too.
if [ -x "$LSREGISTER" ]; then
    sleep 1
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$PREVIOUS" >/dev/null 2>&1 || true
    "$LSREGISTER" -u /Applications/PRISM.app.backup >/dev/null 2>&1 || true
    # Control Center performs a delayed registration pass after launch.
    sleep 2
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$PREVIOUS" >/dev/null 2>&1 || true
    "$LSREGISTER" -u /Applications/PRISM.app.backup >/dev/null 2>&1 || true
fi

# Replacing a live CMIO extension invalidates the app's existing DAL session.
# The app submits the replacement after launch; once sysextd confirms that the
# newly embedded build is active, relaunch exactly once so the sink connects
# to that new provider rather than carrying a dead device object until the
# user's next manual restart.
if [ -n "$ACTIVE_EXTENSION_BEFORE" ] \
   && [ "$ACTIVE_EXTENSION_BEFORE" != "$EXTENSION_BUILD" ]; then
    echo "==> updating PRISM Camera ($ACTIVE_EXTENSION_BEFORE → $EXTENSION_BUILD)"
    extension_updated=0
    for _ in {1..20}; do
        if [ "$(active_extension_build || true)" = "$EXTENSION_BUILD" ]; then
            extension_updated=1
            break
        fi
        sleep 0.5
    done
    if [ "$extension_updated" -eq 1 ] && extension_restart_pending; then
        warn_extension_restart
    elif [ "$extension_updated" -eq 1 ]; then
        echo "==> relaunching against the updated camera extension"
        pkill -x PRISM 2>/dev/null || true
        sleep 1
        open "$INSTALLED"
    else
        echo >&2
        echo "    ⚠  Camera extension update is still pending in macOS." >&2
        echo "       Approve it in System Settings or restart if macOS asks." >&2
    fi
elif extension_restart_pending; then
    # Preserve the warning on subsequent rebuilds until the requested restart
    # really happened; otherwise a second run would misleadingly look clean.
    warn_extension_restart
fi
