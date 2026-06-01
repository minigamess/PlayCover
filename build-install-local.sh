#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DERIVED_DATA_PATH="${ROOT_DIR}/.build/DerivedData"
BUILD_APP_PATH="${DERIVED_DATA_PATH}/Build/Products/Release/PlayCover.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP_PATH="${INSTALL_DIR}/PlayCover.app"

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

printf "==> Bootstrapping Carthage dependencies...\n"
FASTLANE=1 "$CARTHAGE_BIN" update --cache-builds --use-xcframeworks --project-directory "$ROOT_DIR"

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

printf "==> Done. Installed app: %s\n" "$INSTALL_APP_PATH"
printf "==> Launching PlayCover...\n"
open "$INSTALL_APP_PATH"
