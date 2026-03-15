#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
METADATA_FILE="$ROOT_DIR/husi.properties"
DESKTOP_METADATA_FILE="$ROOT_DIR/release/desktop/package-metadata.sh"
MSI_TEMPLATE_FILE="$ROOT_DIR/release/windows/desktop/installer.wxs"
JAR_DIR_DEFAULT="$ROOT_DIR/composeApp/build/compose/jars"
OUTPUT_DIR_DEFAULT="$ROOT_DIR/composeApp/build/compose/packages/windows"
PACKAGE_NAME_PLACEHOLDER="__HUSI_PACKAGE_NAME__"
APP_NAME_PLACEHOLDER="__HUSI_APP_NAME__"
APP_DESCRIPTION_PLACEHOLDER="__HUSI_APP_DESCRIPTION__"
APP_URL_PLACEHOLDER="__HUSI_APP_URL__"
MAINTAINER_PLACEHOLDER="__HUSI_MAINTAINER__"
MSI_VERSION_PLACEHOLDER="__HUSI_MSI_VERSION__"
MSI_DOWNGRADE_ERROR_PLACEHOLDER="__HUSI_MSI_DOWNGRADE_ERROR__"
URL_SCHEME_REGISTRY_PLACEHOLDER="__HUSI_URL_SCHEME_REGISTRY__"
TAG_NAME=""
TAG_EPOCH=""
HOST_OS=""
PYTHON_BIN=""
MSI_BACKEND=""

log() {
    echo "[package] $*"
}

error() {
    echo "[package] $*" >&2
}

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [--formats zip,msi] [--target <platform/arch>] [--input-jar <file>] [--launcher-bin <file>] [--output-dir <dir>]
  $(basename "$0") --check-tools [--formats zip,msi] [--target <platform/arch>]

Description:
  Build Windows portable zip and MSI installer packages from desktop uber jar.

Defaults:
  --formats      zip,msi
  --input-jar    newest matching jar under $JAR_DIR_DEFAULT
  --launcher-bin $ROOT_DIR/launcher/zig-out/bin/launcher-windows-<x86_64|aarch64>.exe
  --output-dir   $OUTPUT_DIR_DEFAULT
EOF
}

require_arg() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" ]]; then
        error "Missing value for $option."
        usage
        exit 1
    fi
}

render_template() {
    local template_file="$1"
    local output_file="$2"
    shift 2

    if [[ ! -f "$template_file" ]]; then
        error "Template file not found: $template_file"
        exit 1
    fi

    if [[ $(( $# % 2 )) -ne 0 ]]; then
        error "render_template requires placeholder/value pairs."
        exit 1
    fi

    "$PYTHON_BIN" - "$template_file" "$output_file" "$@" <<'PY'
import pathlib
import sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
pairs = sys.argv[3:]

if len(pairs) % 2 != 0:
    raise SystemExit("render_template requires placeholder/value pairs")

content = template_path.read_text(encoding="utf-8")
for index in range(0, len(pairs), 2):
    content = content.replace(pairs[index], pairs[index + 1])

output_path.write_text(content, encoding="utf-8")
PY
}

source_desktop_metadata() {
    if [[ ! -f "$DESKTOP_METADATA_FILE" ]]; then
        error "Desktop metadata file not found: $DESKTOP_METADATA_FILE"
        exit 1
    fi

    # shellcheck disable=SC1090
    source "$DESKTOP_METADATA_FILE"
}

resolve_python() {
    if command -v python3 >/dev/null 2>&1; then
        PYTHON_BIN="python3"
        return
    fi
    if command -v python >/dev/null 2>&1; then
        PYTHON_BIN="python"
        return
    fi

    error "Missing required tool: python3"
    exit 2
}

load_metadata() {
    if [[ ! -f "$METADATA_FILE" ]]; then
        error "Metadata file not found: $METADATA_FILE"
        exit 1
    fi

    PACKAGE_NAME="$(awk -F= '$1=="PACKAGE_NAME"{print $2; exit}' "$METADATA_FILE")"
    VERSION_NAME="$(awk -F= '$1=="VERSION_NAME"{print $2; exit}' "$METADATA_FILE")"

    if [[ -z "$PACKAGE_NAME" || -z "$VERSION_NAME" ]]; then
        error "Failed to parse PACKAGE_NAME or VERSION_NAME from $METADATA_FILE"
        exit 1
    fi

    source_desktop_metadata
}

resolve_host_os() {
    case "$(uname -s)" in
        Darwin)
            HOST_OS="darwin"
            ;;
        Linux)
            HOST_OS="linux"
            ;;
        MINGW*|MSYS*|CYGWIN*)
            HOST_OS="windows"
            ;;
        *)
            error "Unsupported host OS '$(uname -s)'. Use Linux, macOS or Windows/MSYS."
            exit 1
            ;;
    esac
}

resolve_tag_epoch() {
    local candidate="v$VERSION_NAME"

    if git rev-parse -q --verify "refs/tags/$candidate" >/dev/null 2>&1; then
        TAG_NAME="$candidate"
        TAG_EPOCH="$(git log -1 --format=%ct "refs/tags/$candidate" | tr -d '\r\n')"
    fi

    if [[ -z "$TAG_NAME" || -z "$TAG_EPOCH" ]]; then
        error "No matching tag found for VERSION_NAME=$VERSION_NAME (required: v$VERSION_NAME)."
        exit 1
    fi

    if [[ ! "$TAG_EPOCH" =~ ^[0-9]+$ ]]; then
        error "Invalid tag epoch '$TAG_EPOCH' from tag '$TAG_NAME'."
        exit 1
    fi
}

normalize_platform() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        windows|win)
            echo "windows"
            ;;
        *)
            error "Unsupported platform '$1'. Use windows."
            exit 1
            ;;
    esac
}

normalize_arch() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$value" in
        amd64|x86_64)
            echo "amd64"
            ;;
        arm64|aarch64)
            echo "arm64"
            ;;
        *)
            error "Unsupported arch '$1'. Use amd64 or arm64."
            exit 1
            ;;
    esac
}

resolve_target() {
    if [[ -n "$TARGET" ]]; then
        local raw_platform="${TARGET%%/*}"
        local raw_arch="${TARGET#*/}"
        if [[ "$raw_platform" == "$raw_arch" ]]; then
            error "Invalid --target '$TARGET'. Use <platform>/<arch>, e.g. windows/amd64."
            exit 1
        fi
        TARGET_PLATFORM="$(normalize_platform "$raw_platform")"
        TARGET_ARCH="$(normalize_arch "$raw_arch")"
        return
    fi

    error "Windows packaging requires --target <platform/arch>, e.g. windows/amd64."
    exit 1
}

resolve_arch() {
    case "$TARGET_ARCH" in
        amd64)
            JAR_ARCH="x64"
            LAUNCHER_MACHINE="x86_64"
            MSI_ARCH="x64"
            ;;
        arm64)
            JAR_ARCH="arm64"
            LAUNCHER_MACHINE="aarch64"
            MSI_ARCH="arm64"
            ;;
        *)
            error "Unsupported architecture '$TARGET_ARCH'."
            exit 1
            ;;
    esac
}

resolve_formats() {
    local value="$1"
    local item
    declare -gA ENABLED_FORMATS=()

    IFS=',' read -r -a items <<<"$value"
    for item in "${items[@]}"; do
        item="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$item" in
            zip)
                ENABLED_FORMATS["zip"]=1
                ;;
            msi|installer)
                ENABLED_FORMATS["msi"]=1
                ;;
            "")
                ;;
            *)
                error "Unknown format '$item'. Use zip,msi."
                exit 1
                ;;
        esac
    done

    if [[ "${#ENABLED_FORMATS[@]}" -eq 0 ]]; then
        error "No valid formats selected."
        exit 1
    fi
}

resolve_msi_backend() {
    if [[ -z "${ENABLED_FORMATS[msi]:-}" ]]; then
        return
    fi

    if command -v wixl >/dev/null 2>&1; then
        MSI_BACKEND="wixl"
        return
    fi
    if command -v wix >/dev/null 2>&1; then
        MSI_BACKEND="wix"
        return
    fi
    if command -v wix.exe >/dev/null 2>&1; then
        MSI_BACKEND="wix.exe"
        return
    fi

    error "Missing MSI builder. Install wixl or WiX Toolset."
    exit 2
}

require_tools() {
    local -a tools=(awk sed cp mkdir mktemp git sort head rm "$PYTHON_BIN")
    local -a missing=()
    local tool

    if [[ "$MSI_BACKEND" == "wixl" ]]; then
        tools+=(msiinfo msibuild)
    fi

    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        exit 2
    fi
}

touch_path() {
    local path="$1"
    "$PYTHON_BIN" - "$TAG_EPOCH" "$path" <<'PY'
import os
import sys

epoch = int(sys.argv[1])
path = sys.argv[2]
os.utime(path, (epoch, epoch))
PY
}

touch_path_tree() {
    local root="$1"
    "$PYTHON_BIN" - "$TAG_EPOCH" "$root" <<'PY'
import os
import sys

epoch = int(sys.argv[1])
root = sys.argv[2]

for current, dir_names, file_names in os.walk(root):
    os.utime(current, (epoch, epoch))
    dir_names.sort()
    file_names.sort()
    for file_name in file_names:
        os.utime(os.path.join(current, file_name), (epoch, epoch))
PY
}

normalize_msi_version() {
    "$PYTHON_BIN" - "$VERSION_NAME" <<'PY'
import re
import sys

parts = [int(part) for part in re.findall(r"\d+", sys.argv[1])]
if not parts:
    raise SystemExit("invalid")
while len(parts) < 3:
    parts.append(0)

major, minor, build = parts[:3]
if major > 255 or minor > 255 or build > 65535:
    raise SystemExit("out-of-range")

print(f"{major}.{minor}.{build}")
PY
}

resolve_input_jar() {
    local requested="$1"
    if [[ -n "$requested" ]]; then
        if [[ ! -f "$requested" ]]; then
            error "Input jar not found: $requested"
            exit 1
        fi
        INPUT_JAR="$requested"
        return
    fi

    local exact="$JAR_DIR_DEFAULT/${PACKAGE_NAME}-windows-${JAR_ARCH}-${VERSION_NAME}.jar"
    if [[ -f "$exact" ]]; then
        INPUT_JAR="$exact"
        return
    fi

    local latest=""
    local -a matches=()
    shopt -s nullglob
    matches=("$JAR_DIR_DEFAULT"/${PACKAGE_NAME}-windows-${JAR_ARCH}-*.jar)
    shopt -u nullglob
    if [[ "${#matches[@]}" -gt 0 ]]; then
        latest="$(ls -t "${matches[@]}" 2>/dev/null | head -n 1)"
    fi
    if [[ -n "$latest" ]]; then
        INPUT_JAR="$latest"
        return
    fi

    error "No matching desktop jar found in $JAR_DIR_DEFAULT"
    error "Build one first: ./gradlew -p composeApp packageUberJarForCurrentOS -PdesktopTarget=windows/$TARGET_ARCH"
    exit 1
}

resolve_launcher_bin() {
    local requested="$1"
    local default_path="$ROOT_DIR/launcher/zig-out/bin/launcher-${TARGET_PLATFORM}-${LAUNCHER_MACHINE}.exe"

    if [[ -n "$requested" ]]; then
        if [[ ! -f "$requested" ]]; then
            error "Launcher binary not found: $requested"
            exit 1
        fi
        INPUT_LAUNCHER_BIN="$requested"
        return
    fi

    if [[ -f "$default_path" ]]; then
        INPUT_LAUNCHER_BIN="$default_path"
        return
    fi

    error "Launcher binary not found: $default_path"
    error "Build one first: cd launcher && zig build -Doptimize=ReleaseSmall -Dtarget=${LAUNCHER_MACHINE}-windows"
    exit 1
}

windows_url_scheme_registry_entries() {
    local scheme
    for scheme in "${DESKTOP_URL_SCHEMES[@]}"; do
        cat <<EOF
        <RegistryValue Root="HKCU" Key="Software\\Classes\\$scheme" Type="string" Value="URL:$scheme Protocol" />
        <RegistryValue Root="HKCU" Key="Software\\Classes\\$scheme" Name="URL Protocol" Type="string" Value="" />
        <RegistryValue Root="HKCU" Key="Software\\Classes\\$scheme\\DefaultIcon" Type="string" Value="[#MainExecutableFile],0" />
        <RegistryValue Root="HKCU" Key="Software\\Classes\\$scheme\\shell\\open\\command" Type="string" Value="&quot;[#MainExecutableFile]&quot; &quot;%1&quot;" />
EOF
    done
}

prepare_rootfs() {
    local root="$1"
    local launcher_name="$APP_NAME.exe"
    local launcher_path="$root/$launcher_name"

    mkdir -p "$root/app"
    cp "$INPUT_JAR" "$root/app/$PACKAGE_NAME.jar"
    cp "$INPUT_LAUNCHER_BIN" "$launcher_path"
    chmod 755 "$launcher_path"
    cp "$ROOT_DIR/release/linux/desktop/desktop-java-opts.conf" "$root/desktop-java-opts.conf.template"
    cp "$ROOT_DIR/release/linux/desktop/desktop-app-args.conf" "$root/desktop-app-args.conf.template"
    cp "$ROOT_DIR/LICENSE" "$root/LICENSE"
    touch_path_tree "$root"
}

build_zip() {
    local portable_root="$1"
    local output_path="$OUTPUT_DIR/${PACKAGE_NAME}-${VERSION_NAME}-windows-${TARGET_ARCH}.zip"

    rm -f "$output_path"
    "$PYTHON_BIN" - "$portable_root" "$output_path" <<'PY'
import os
import sys
import zipfile

root = os.path.abspath(sys.argv[1])
output_path = os.path.abspath(sys.argv[2])
parent = os.path.dirname(root)

with zipfile.ZipFile(output_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for current, dir_names, file_names in os.walk(root):
        dir_names.sort()
        file_names.sort()
        rel_dir = os.path.relpath(current, parent).replace(os.sep, "/")
        if rel_dir != ".":
            archive.write(current, rel_dir.rstrip("/") + "/")
        for file_name in file_names:
            path = os.path.join(current, file_name)
            arcname = os.path.relpath(path, parent).replace(os.sep, "/")
            archive.write(path, arcname)
PY
    touch_path "$output_path"
    log "Built zip: $output_path"
}

write_msi_source() {
    local output_file="$1"
    local msi_version="$2"
    local url_scheme_registry
    local downgrade_error

    if [[ ! -f "$MSI_TEMPLATE_FILE" ]]; then
        error "MSI template file not found: $MSI_TEMPLATE_FILE"
        exit 1
    fi

    url_scheme_registry="$(windows_url_scheme_registry_entries)"
    downgrade_error="A newer version of $APP_NAME is already installed."

    render_template \
        "$MSI_TEMPLATE_FILE" \
        "$output_file" \
        "$PACKAGE_NAME_PLACEHOLDER" "$PACKAGE_NAME" \
        "$APP_NAME_PLACEHOLDER" "$APP_NAME" \
        "$APP_DESCRIPTION_PLACEHOLDER" "$APP_DESCRIPTION" \
        "$APP_URL_PLACEHOLDER" "$APP_URL" \
        "$MAINTAINER_PLACEHOLDER" "$MAINTAINER" \
        "$MSI_VERSION_PLACEHOLDER" "$msi_version" \
        "$MSI_DOWNGRADE_ERROR_PLACEHOLDER" "$downgrade_error" \
        "$URL_SCHEME_REGISTRY_PLACEHOLDER" "$url_scheme_registry"
}

build_msi() {
    local work_dir="$1"
    local msi_source="$work_dir/installer.wxs"
    local output_path="$OUTPUT_DIR/${PACKAGE_NAME}-${VERSION_NAME}-windows-${TARGET_ARCH}-installer.msi"
    local msi_version

    msi_version="$(normalize_msi_version)" || {
        error "VERSION_NAME=$VERSION_NAME cannot be converted to a valid MSI version."
        exit 1
    }

    write_msi_source "$msi_source" "$msi_version"
    rm -f "$output_path"

    case "$MSI_BACKEND" in
        wixl)
            (
                cd "$work_dir"
                if [[ "$MSI_ARCH" == "arm64" ]]; then
                    wixl -a x64 -o "$output_path" installer.wxs
                    local package_code
                    package_code="$(msiinfo export "$output_path" _SummaryInformation | awk -F '\t' '$1==9 {print $2}')"
                    msibuild "$output_path" -s "$APP_NAME" "$MAINTAINER" "Arm64;1033" "$package_code"
                else
                    wixl -a "$MSI_ARCH" -o "$output_path" installer.wxs
                fi
            )
            ;;
        wix|wix.exe)
            (
                cd "$work_dir"
                "$MSI_BACKEND" build -arch "$MSI_ARCH" -out "$output_path" installer.wxs
            )
            ;;
        *)
            error "Unsupported MSI backend: $MSI_BACKEND"
            exit 1
            ;;
    esac

    touch_path "$output_path"
    log "Built MSI: $output_path"
}

TARGET=""
TARGET_PLATFORM=""
TARGET_ARCH=""
INPUT_JAR=""
INPUT_LAUNCHER_BIN=""
OUTPUT_DIR="$OUTPUT_DIR_DEFAULT"
FORMATS="zip,msi"
CHECK_TOOLS=0
PACKAGE_NAME=""
VERSION_NAME=""
APP_NAME=""
APP_DESCRIPTION=""
APP_URL=""
MAINTAINER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            require_arg "$1" "${2:-}"
            TARGET="$2"
            shift 2
            ;;
        --formats)
            require_arg "$1" "${2:-}"
            FORMATS="$2"
            shift 2
            ;;
        -i|--input-jar)
            require_arg "$1" "${2:-}"
            INPUT_JAR="$2"
            shift 2
            ;;
        --launcher-bin)
            require_arg "$1" "${2:-}"
            INPUT_LAUNCHER_BIN="$2"
            shift 2
            ;;
        -o|--output-dir)
            require_arg "$1" "${2:-}"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --check-tools)
            CHECK_TOOLS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

resolve_python
load_metadata
resolve_host_os
resolve_target
resolve_arch
resolve_formats "$FORMATS"
resolve_tag_epoch
resolve_msi_backend
require_tools

if [[ "$CHECK_TOOLS" -eq 1 ]]; then
    log "All required tools are available for target: windows/$TARGET_ARCH"
    exit 0
fi

resolve_input_jar "$INPUT_JAR"
resolve_launcher_bin "$INPUT_LAUNCHER_BIN"
mkdir -p "$OUTPUT_DIR"

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

portable_root="$work_dir/${APP_NAME}-${VERSION_NAME}-windows-${TARGET_ARCH}"
installer_root="$work_dir/installer-root"

prepare_rootfs "$portable_root"
prepare_rootfs "$installer_root"

if [[ -n "${ENABLED_FORMATS[zip]:-}" ]]; then
    build_zip "$portable_root"
fi
if [[ -n "${ENABLED_FORMATS[msi]:-}" ]]; then
    build_msi "$work_dir"
fi

log "Done. Output directory: $OUTPUT_DIR"
