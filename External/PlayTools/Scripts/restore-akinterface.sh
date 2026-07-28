#!/usr/bin/env bash
# Restore the full macOS AKInterface.bundle into PlayTools.framework/PlugIns.
#
# AKInterface is a macOS AppKit plugin. When PlayTools is built for iphoneos,
# Xcode's "Embed Frameworks" (CodeSignOnCopy) often drops the Mach-O, leaving
# an empty Contents/MacOS/ — games then crash on AKInterface.shared!.
#
# Usages:
#   1) Xcode Run Script phase (uses TARGET_BUILD_DIR / FULL_PRODUCT_NAME / BUILD_DIR)
#   2) CLI: restore-akinterface.sh <AKInterface.bundle> <PlayTools.framework>

set -euo pipefail

ak_binary_path() {
    local bundle="$1"
    if [[ -f "${bundle}/Contents/MacOS/AKInterface" ]]; then
        printf '%s\n' "${bundle}/Contents/MacOS/AKInterface"
        return 0
    fi
    # Flat layout (unlikely for macOS, but be tolerant)
    if [[ -f "${bundle}/AKInterface" ]]; then
        printf '%s\n' "${bundle}/AKInterface"
        return 0
    fi
    return 1
}

find_source_bundle() {
    local candidate
    for candidate in "$@"; do
        [[ -z "${candidate}" ]] && continue
        if ak_binary_path "${candidate}" >/dev/null 2>&1; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

restore_into_framework() {
    local src="$1"
    local fw="$2"
    local dst="${fw}/PlugIns/AKInterface.bundle"
    local bin

    if [[ ! -d "${fw}" ]]; then
        printf "error: PlayTools.framework not found: %s\n" "${fw}" >&2
        return 1
    fi
    if ! bin="$(ak_binary_path "${src}")"; then
        printf "error: source AKInterface.bundle has no binary: %s\n" "${src}" >&2
        return 1
    fi

    mkdir -p "${fw}/PlugIns"
    rm -rf "${dst}"
    ditto "${src}" "${dst}"

    if ! bin="$(ak_binary_path "${dst}")"; then
        printf "error: AKInterface binary missing after restore into %s\n" "${fw}" >&2
        return 1
    fi
    chmod +x "${bin}"
    printf "note: Restored AKInterface (%s) → %s\n" \
        "$(du -h "${bin}" | awk '{print $1}')" "${dst}"
}

# --- CLI mode: explicit source + framework ---
if [[ $# -ge 2 ]]; then
    restore_into_framework "$1" "$2"
    exit 0
fi

# --- Xcode Run Script mode ---
if [[ -n "${TARGET_BUILD_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
    fw="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
    dst_bundle="${fw}/PlugIns/AKInterface.bundle"

    # Already good (e.g. re-run / incremental with prior restore)
    if ak_binary_path "${dst_bundle}" >/dev/null 2>&1; then
        printf "note: AKInterface.bundle already contains binary\n"
        exit 0
    fi

    configuration="${CONFIGURATION:-Release}"
    build_dir="${BUILD_DIR:-}"
    products_dir="${BUILT_PRODUCTS_DIR:-}"

    src="$(find_source_bundle \
        "${build_dir}/${configuration}/AKInterface.bundle" \
        "${build_dir}/Release/AKInterface.bundle" \
        "${products_dir}/../${configuration}/AKInterface.bundle" \
        "${products_dir}/../Release/AKInterface.bundle" \
        || true)"

    if [[ -z "${src}" ]]; then
        printf "error: could not find AKInterface.bundle with MacOS binary\n" >&2
        printf "  BUILD_DIR=%s\n" "${build_dir:-<unset>}" >&2
        printf "  CONFIGURATION=%s\n" "${configuration}" >&2
        printf "  BUILT_PRODUCTS_DIR=%s\n" "${products_dir:-<unset>}" >&2
        printf "  (Build the AKInterface target for macOS first.)\n" >&2
        exit 1
    fi

    restore_into_framework "${src}" "${fw}"
    exit 0
fi

printf "usage: %s <AKInterface.bundle> <PlayTools.framework>\n" "$(basename "$0")" >&2
printf "   or: run as an Xcode Run Script phase after Embed Frameworks\n" >&2
exit 2
