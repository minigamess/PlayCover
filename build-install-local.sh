#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_PATH="${ROOT_DIR}/.build/DerivedData"
BUILD_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/PlayCover.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP_PATH="${INSTALL_DIR}/PlayCover.app"
VENDOR_PLAYTOOLS="${ROOT_DIR}/External/PlayTools"
CHECKOUT_PLAYTOOLS="${ROOT_DIR}/Carthage/Checkouts/PlayTools"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf "Missing required command: %s\n" "$1" >&2
        exit 1
    fi
}

ad_hoc_resign_app() {
    local app_path="$1"

    printf "==> Re-signing app bundle ad-hoc (unify Team ID)...\n"
    codesign --force --deep --sign - --timestamp=none "$app_path"
    codesign --verify --deep --strict "$app_path"
}

setup_developer_dir() {
    local selected=""
    local xcode_dev_dir="/Applications/Xcode.app/Contents/Developer"

    if command -v xcode-select >/dev/null 2>&1; then
        selected="$(xcode-select -p 2>/dev/null || true)"
    fi

    if [[ -n "$selected" && -x "$selected/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$selected"
        return 0
    fi

    if [[ -d "$xcode_dev_dir" && -x "$xcode_dev_dir/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$xcode_dev_dir"
        return 0
    fi

    return 1
}

find_carthage() {
    if command -v carthage >/dev/null 2>&1; then
        command -v carthage
        return
    fi

    for candidate in /opt/homebrew/bin/carthage /usr/local/bin/carthage /opt/local/bin/carthage; do
        if [[ -x "$candidate" ]]; then
            printf "%s\n" "$candidate"
            return
        fi
    done

    return 1
}

ensure_carthage() {
    local bin

    if bin="$(find_carthage)"; then
        printf "%s\n" "$bin"
        return 0
    fi

    if command -v brew >/dev/null 2>&1; then
        printf "==> carthage not found, installing via Homebrew...\n" >&2
        brew install carthage >&2
        if bin="$(find_carthage)"; then
            printf "%s\n" "$bin"
            return 0
        fi
    fi

    return 1
}

sync_vendored_playtools() {
    if [[ ! -d "$VENDOR_PLAYTOOLS/PlayTools.xcodeproj" ]]; then
        printf "Vendored PlayTools not found at %s\n" "$VENDOR_PLAYTOOLS" >&2
        printf "Expected original PlayTools sources under External/PlayTools (committed in git).\n" >&2
        exit 1
    fi

    printf "==> Syncing vendored PlayTools → Carthage/Checkouts/PlayTools...\n"
    mkdir -p "${ROOT_DIR}/Carthage/Checkouts"
    rm -rf "$CHECKOUT_PLAYTOOLS"
    # Prefer rsync if available (excludes junk); fall back to cp
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
            --exclude '.git' \
            --exclude 'xcuserdata' \
            --exclude 'DerivedData' \
            "$VENDOR_PLAYTOOLS/" "$CHECKOUT_PLAYTOOLS/"
    else
        cp -R "$VENDOR_PLAYTOOLS" "$CHECKOUT_PLAYTOOLS"
    fi

    # Carthage expects a git repo in Checkouts for some workflows; init a local one
    if [[ ! -d "$CHECKOUT_PLAYTOOLS/.git" ]]; then
        git -C "$CHECKOUT_PLAYTOOLS" init -q
        git -C "$CHECKOUT_PLAYTOOLS" add -A
        git -C "$CHECKOUT_PLAYTOOLS" \
            -c user.email="playcover-local@localhost" \
            -c user.name="PlayCover Local" \
            commit -qm "vendored PlayTools" || true
    fi
}

require_cmd ditto
require_cmd codesign

if ! setup_developer_dir; then
    printf "Xcode toolchain not ready.\n" >&2
    printf "Please install Xcode from App Store, then run once:\n" >&2
    printf "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n" >&2
    exit 1
fi

if ! xcrun --find xcodebuild >/dev/null 2>&1; then
    printf "xcodebuild is unavailable for current developer directory.\n" >&2
    printf "Current DEVELOPER_DIR: %s\n" "${DEVELOPER_DIR:-<unset>}" >&2
    printf "Try:\n" >&2
    printf "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\n" >&2
    exit 1
fi

if ! CARTHAGE_BIN="$(ensure_carthage)"; then
    printf "Missing required command: carthage\n" >&2
    if ! command -v brew >/dev/null 2>&1; then
        printf "Homebrew not found. Install Homebrew first, then run: brew install carthage\n" >&2
    else
        printf "Tried auto-install with Homebrew but carthage is still unavailable.\n" >&2
    fi
    exit 1
fi

# Do NOT run `carthage update` — it re-fetches PlayTools and wipes local/vendored sources.
sync_vendored_playtools

printf "==> Building PlayTools (iphoneos) via xcodebuild...\n"
# carthage build often exits 0 with empty iOS products on newer Xcode; build directly.
PLAYTOOLS_DD="${ROOT_DIR}/.build/PlayTools-iOS"
PLAYTOOLS_FW="${PLAYTOOLS_DD}/Build/Products/Release-iphoneos/PlayTools.framework"
rm -rf "${ROOT_DIR}/Carthage/Build/PlayTools.xcframework"
rm -f "${ROOT_DIR}/Carthage/Build/.PlayTools.version"
FASTLANE=1 xcodebuild \
    -project "${CHECKOUT_PLAYTOOLS}/PlayTools.xcodeproj" \
    -scheme PlayTools \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$PLAYTOOLS_DD" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    ONLY_ACTIVE_ARCH=NO \
    build

if [[ ! -f "${PLAYTOOLS_FW}/PlayTools" ]]; then
    printf "PlayTools framework binary missing: %s\n" "${PLAYTOOLS_FW}/PlayTools" >&2
    exit 1
fi

printf "==> Packaging PlayTools.xcframework for Carthage copy step...\n"
XCFW="${ROOT_DIR}/Carthage/Build/PlayTools.xcframework"
mkdir -p "${XCFW}/ios-arm64"
ditto "$PLAYTOOLS_FW" "${XCFW}/ios-arm64/PlayTools.framework"
cat > "${XCFW}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>PlayTools.framework/PlayTools</string>
			<key>LibraryIdentifier</key>
			<string>ios-arm64</string>
			<key>LibraryPath</key>
			<string>PlayTools.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>ios</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

printf "==> Building PlayCover (ad-hoc signing, no certificate required)...\n"
xcodebuild \
    -project "$ROOT_DIR/PlayCover.xcodeproj" \
    -scheme PlayCover \
    -configuration Release \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    FASTLANE=1 \
    LOCAL_BUILD_NO_SIGN=1 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="-" \
    EXPANDED_CODE_SIGN_IDENTITY_NAME="-" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build

if [[ ! -d "$BUILD_APP_PATH" ]]; then
    printf "Build output not found: %s\n" "$BUILD_APP_PATH" >&2
    exit 1
fi

ad_hoc_resign_app "$BUILD_APP_PATH"

printf "==> Closing running PlayCover instance (if any)...\n"
pkill -x PlayCover >/dev/null 2>&1 || true

printf "==> Installing to %s...\n" "$INSTALL_DIR"
if [[ ! -d "$INSTALL_DIR" ]]; then
    if [[ -w "$(dirname "$INSTALL_DIR")" ]]; then
        mkdir -p "$INSTALL_DIR"
    else
        sudo mkdir -p "$INSTALL_DIR"
    fi
fi

if [[ -w "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_APP_PATH"
    ditto "$BUILD_APP_PATH" "$INSTALL_APP_PATH"
else
    sudo rm -rf "$INSTALL_APP_PATH"
    sudo ditto "$BUILD_APP_PATH" "$INSTALL_APP_PATH"
fi

xattr -dr com.apple.quarantine "$INSTALL_APP_PATH" >/dev/null 2>&1 || true

# Keep system PlayTools in sync (apps inject from ~/Library/Frameworks)
printf "==> Installing PlayTools framework to ~/Library/Frameworks...\n"
mkdir -p "${HOME}/Library/Frameworks"
rm -rf "${HOME}/Library/Frameworks/PlayTools.framework"
ditto "${INSTALL_APP_PATH}/Contents/Frameworks/PlayTools.framework" \
    "${HOME}/Library/Frameworks/PlayTools.framework"

printf "==> Done. Installed app: %s\n" "$INSTALL_APP_PATH"
printf "==> Launching PlayCover...\n"
open "$INSTALL_APP_PATH"
