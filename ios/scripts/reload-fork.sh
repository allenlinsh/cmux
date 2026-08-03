#!/usr/bin/env bash
# Build and install the iOS app from a personal fork, without Manaflow signing.
#
# Companion to scripts/reload-fork.sh (Mac). Personal values come from env vars
# or a `.fork-config` file at the repo root (sourced as shell; quote spaces).
# Keep `.fork-config` out of git (see .git/info/exclude).
#
#   FORK_BUNDLE_ID       required. Your Mac app namespace, e.g. dev.you.cmux.staging
#                        (never com.cmuxterm.*). Used to derive the iOS bundle id
#                        when FORK_IOS_BUNDLE_ID is unset.
#   FORK_IOS_BUNDLE_ID   optional. Defaults to "${FORK_BUNDLE_ID}.ios".
#   FORK_TEAM_ID         required for a physical device. Apple team ID (free
#                        personal teams work with the stripped fork entitlements).
#   FORK_APP_NAME        optional Mac/display name. Default: "cmux fork".
#   FORK_IOS_APP_NAME    optional iOS display name. Default: $FORK_APP_NAME.
#
# This is a Release build under your own bundle id (not Debug-tagged DEV). That
# matches the Mac fork Release path: iOS treats non-beta Release as official and
# pairs with Mac instance tag "default", which is what reload-fork.sh produces
# for custom bundle ids. Do not use ios/scripts/reload.sh --tag for this path if
# your Mac is the fork Release app — those two channels are incompatible.
#
# Usage:
#   ios/scripts/reload-fork.sh                 # build + install + launch on phone
#   ios/scripts/reload-fork.sh --no-install    # build only
#   ios/scripts/reload-fork.sh --no-launch     # install but do not launch
#   ios/scripts/reload-fork.sh --simulator     # simulator instead of device
#   ios/scripts/reload-fork.sh --device-id ID  # specific phone
#   ios/scripts/reload-fork.sh --allow-device-registration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$IOS_DIR/.." && pwd)"
cd "$REPO_ROOT"

INSTALL=1
LAUNCH=1
TARGET="device"
DEVICE_ID="${IOS_DEVICE_ID:-}"
DEVICE_NAME="${IOS_DEVICE_NAME:-}"
ALLOW_DEVICE_REGISTRATION=0
SIMULATOR_NAME="${IOS_SIMULATOR_NAME:-iPhone 17}"
SIMULATOR_ID="${IOS_SIMULATOR_ID:-}"

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "error: missing value for $option" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      INSTALL=1
      shift
      ;;
    --no-install)
      INSTALL=0
      shift
      ;;
    --no-launch)
      LAUNCH=0
      shift
      ;;
    --simulator|--sim)
      TARGET="simulator"
      shift
      ;;
    --device)
      TARGET="device"
      shift
      ;;
    --device-id)
      require_option_value "$1" "${2:-}"
      DEVICE_ID="${2:-}"
      TARGET="device"
      shift 2
      ;;
    --device-name)
      require_option_value "$1" "${2:-}"
      DEVICE_NAME="${2:-}"
      TARGET="device"
      shift 2
      ;;
    --simulator-name)
      require_option_value "$1" "${2:-}"
      SIMULATOR_NAME="${2:-}"
      TARGET="simulator"
      shift 2
      ;;
    --simulator-id)
      require_option_value "$1" "${2:-}"
      SIMULATOR_ID="${2:-}"
      TARGET="simulator"
      shift 2
      ;;
    --allow-device-registration)
      ALLOW_DEVICE_REGISTRATION=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -f .fork-config ]]; then
  # shellcheck disable=SC1091
  source .fork-config
fi

FORK_APP_NAME="${FORK_APP_NAME:-cmux fork}"
FORK_IOS_APP_NAME="${FORK_IOS_APP_NAME:-$FORK_APP_NAME}"
FORK_TEAM_ID="${FORK_TEAM_ID:-${IOS_DEVELOPMENT_TEAM:-}}"

if [[ -z "${FORK_BUNDLE_ID:-}" ]]; then
  echo "error: FORK_BUNDLE_ID is not set." >&2
  echo "Set it in .fork-config or the environment, e.g.:" >&2
  echo "  echo 'FORK_BUNDLE_ID=dev.you.cmux.staging' >> .fork-config" >&2
  echo "Use your own namespace: com.cmuxterm.* / com.cmux.app / dev.cmux.* belong to Manaflow." >&2
  exit 1
fi

FORK_IOS_BUNDLE_ID="${FORK_IOS_BUNDLE_ID:-${FORK_BUNDLE_ID}.ios}"

case "$FORK_IOS_BUNDLE_ID" in
  com.cmuxterm.*|com.cmux.app|com.cmux.app.*|dev.cmux.app|dev.cmux.app.*|dev.cmux.ios|dev.cmux.ios.*)
    echo "error: FORK_IOS_BUNDLE_ID='$FORK_IOS_BUNDLE_ID' is a Manaflow-owned id." >&2
    echo "Use your own namespace, e.g. ${FORK_BUNDLE_ID}.ios" >&2
    exit 1
    ;;
esac

if [[ "$TARGET" == "device" && -z "$FORK_TEAM_ID" ]]; then
  echo "error: FORK_TEAM_ID is required for a physical device install." >&2
  echo "Add it to .fork-config (same team as scripts/reload-fork.sh), e.g.:" >&2
  echo "  echo 'FORK_TEAM_ID=XXXXXXXXXX' >> .fork-config" >&2
  echo "Find it in Xcode → Settings → Accounts → Manage Certificates / Team ID." >&2
  exit 1
fi

WORKSPACE="$IOS_DIR/cmux.xcworkspace"
SCHEME="cmux-ios"
DERIVED_DATA="${CMUX_FORK_IOS_DERIVED_DATA:-/tmp/cmux-ios-fork}"
ENTITLEMENTS="$IOS_DIR/Config/fork-dev.entitlements"
GHOSTTYKIT_ENSURE="$REPO_ROOT/scripts/ensure-ghosttykit.sh"
QUEUE_SCRIPT="$REPO_ROOT/scripts/iphone-install-queue.sh"

if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: missing $ENTITLEMENTS" >&2
  exit 1
fi

if [[ -x "$GHOSTTYKIT_ENSURE" ]]; then
  "$GHOSTTYKIT_ENSURE"
fi

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
if [[ -n "$GIT_SHA" ]] && [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)" ]]; then
  GIT_SHA="${GIT_SHA}+"
fi

CONFIGURATION="Release"
PRODUCTS_DIR="Release-iphoneos"
DESTINATION="generic/platform=iOS"
if [[ "$TARGET" == "simulator" ]]; then
  PRODUCTS_DIR="Release-iphonesimulator"
  if [[ -n "$SIMULATOR_ID" ]]; then
    DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
  else
    DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"
  fi
fi

BUILD_ARGS=(
  xcodebuild
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
  PRODUCT_BUNDLE_IDENTIFIER="$FORK_IOS_BUNDLE_ID"
  PRODUCT_DISPLAY_NAME="$FORK_IOS_APP_NAME"
  CODE_SIGN_STYLE=Automatic
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS"
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGN_IDENTITY="Apple Development"
  EXCLUDED_SOURCE_FILE_NAMES=Info.plist
  CMUX_GIT_SHA="$GIT_SHA"
  CMUX_DEV_TAG=
  # Leave auth on Release defaults (production Stack / cmux.com). Override via
  # CMUX_IOS_AUTH_ENV if you need development auth on a fork install.
  CMUX_IOS_AUTH_ENV="${CMUX_IOS_AUTH_ENV:-}"
  CMUX_API_BASE_URL="${CMUX_IOS_API_BASE_URL:-${CMUX_API_BASE_URL:-}}"
  CMUX_IROH_BROKER_BASE_URL="${CMUX_IOS_IROH_BROKER_BASE_URL:-${CMUX_IROH_BROKER_BASE_URL:-}}"
  CMUX_PRESENCE_BASE_URL="${CMUX_PRESENCE_BASE_URL:-}"
  # Force development signing even on Release so we can install with devicectl
  # without an App Store distribution profile.
  PROVISIONING_PROFILE_SPECIFIER=
)

if [[ -n "$FORK_TEAM_ID" ]]; then
  BUILD_ARGS+=("DEVELOPMENT_TEAM=$FORK_TEAM_ID" -allowProvisioningUpdates)
  echo "==> iOS fork build signed with team $FORK_TEAM_ID ($FORK_IOS_BUNDLE_ID)"
else
  echo "==> iOS fork simulator build ($FORK_IOS_BUNDLE_ID); set FORK_TEAM_ID for device installs"
fi

if [[ "$TARGET" == "device" && "$ALLOW_DEVICE_REGISTRATION" -eq 1 ]]; then
  BUILD_ARGS+=(-allowProvisioningDeviceRegistration)
fi

BUILD_ARGS+=(build)

BUILD_LOG="${TMPDIR:-/tmp}/cmux-ios-fork-build.log"
set +e
"${BUILD_ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
BUILD_STATUS="${PIPESTATUS[0]}"
set -e
if [[ "$BUILD_STATUS" -ne 0 ]]; then
  if grep -Eiq "No Accounts|No profiles|requires a development team|provisioning profile|No signing certificate|doesn't include the selected device|Signing for" "$BUILD_LOG"; then
    cat >&2 <<EOF
error: iOS fork build could not sign for the device.

Checklist:
  1. Xcode → Settings → Accounts → add your Apple ID / team $FORK_TEAM_ID
  2. Plug in the iPhone, unlock, Trust, enable Developer Mode
  3. Retry with: ios/scripts/reload-fork.sh --allow-device-registration
  4. Confirm FORK_IOS_BUNDLE_ID is in YOUR namespace (not dev.cmux.* / com.cmuxterm.*)

Build log: $BUILD_LOG
EOF
  else
    echo "error: iOS fork build failed. Log: $BUILD_LOG" >&2
  fi
  exit "$BUILD_STATUS"
fi

APP_PATH="$DERIVED_DATA/Build/Products/$PRODUCTS_DIR/cmux.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build succeeded but app not found at $APP_PATH" >&2
  exit 1
fi

# Apply display name post-build (global PRODUCT_NAME overrides break multi-target
# builds; same pattern as scripts/reload-fork.sh).
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $FORK_IOS_APP_NAME" "$APP_PATH/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName $FORK_IOS_APP_NAME" "$APP_PATH/Info.plist" 2>/dev/null || true

echo
echo "App path:"
echo "  $APP_PATH"
echo "Bundle id:"
echo "  $FORK_IOS_BUNDLE_ID"
echo "Display name:"
echo "  $FORK_IOS_APP_NAME"

if [[ "$INSTALL" -eq 0 ]]; then
  cat <<EOF

Build only (--no-install). To install later:
  xcrun devicectl device install app --device <id> "$APP_PATH"

Pair with the Mac fork Release app from scripts/reload-fork.sh --install
(instance tag "default"). Sign in on both with the same Stack account.
EOF
  exit 0
fi

if [[ "$TARGET" == "simulator" ]]; then
  if [[ -n "$SIMULATOR_ID" ]]; then
    SIM_ID="$SIMULATOR_ID"
  else
    SIM_ID="$(SIMULATOR_NAME="$SIMULATOR_NAME" /usr/bin/python3 - <<'PY'
import json, os, subprocess, sys
name = os.environ["SIMULATOR_NAME"]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
for runtimes in data.get("devices", {}).values():
    for device in runtimes:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)
print(f"error: simulator not found: {name}", file=sys.stderr)
raise SystemExit(1)
PY
)"
  fi
  echo "==> Installing on simulator $SIM_ID"
  xcrun simctl boot "$SIM_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$SIM_ID" "$APP_PATH"
  if [[ "$LAUNCH" -eq 1 ]]; then
    xcrun simctl terminate "$SIM_ID" "$FORK_IOS_BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl launch "$SIM_ID" "$FORK_IOS_BUNDLE_ID" >/dev/null
  fi
  echo "==> iOS fork simulator install succeeded"
  exit 0
fi

# Resolve default device id the same way as ios/scripts/reload.sh.
if [[ -z "$DEVICE_ID" && -z "$DEVICE_NAME" && -x "$QUEUE_SCRIPT" ]]; then
  DEVICE_ID="$("$QUEUE_SCRIPT" default-device 2>/dev/null | head -n1 | tr -d '[:space:]' || true)"
fi

select_device() {
  IOS_DEVICE_ID_REQUEST="$DEVICE_ID" IOS_DEVICE_NAME_REQUEST="$DEVICE_NAME" /usr/bin/python3 - <<'PY'
import json, os, subprocess, sys, tempfile

requested_id = os.environ.get("IOS_DEVICE_ID_REQUEST", "")
requested_name = os.environ.get("IOS_DEVICE_NAME_REQUEST", "")

with tempfile.NamedTemporaryFile() as output:
    result = subprocess.run(
        ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr, end="")
        raise SystemExit(result.returncode)
    output.seek(0)
    data = json.load(output)

devices = []
for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    if hardware.get("platform") != "iOS":
        continue
    if hardware.get("reality") != "physical":
        continue
    if connection.get("pairingState") != "paired":
        continue
    coredevice_id = str(device.get("identifier") or "")
    hardware_udid = str(hardware.get("udid") or "")
    destination_id = hardware_udid or coredevice_id
    install_id = coredevice_id or hardware_udid
    if not destination_id or not install_id:
        continue
    name = properties.get("name") or destination_id
    tunnel = str(connection.get("tunnelState") || "")
    boot = str(properties.get("bootState") || "")
    available = tunnel.lower() in ("connected", "ready") or boot.lower() == "booted"
    devices.append({
        "identifier": destination_id,
        "install_identifier": install_id,
        "name": name,
        "available": available,
        "boot": boot,
        "tunnel": tunnel,
        "ids": {coredevice_id, hardware_udid},
    })

if requested_id:
    for device in devices:
        if requested_id in device["ids"] or requested_id == device["identifier"]:
            print(f"{device['identifier']}\t{device['install_identifier']}\t{device['name']}")
            raise SystemExit(0)
    print(f"error: requested device id not found: {requested_id}", file=sys.stderr)
    raise SystemExit(1)

if requested_name:
    matches = [d for d in devices if d["name"] == requested_name]
    if not matches:
        matches = [d for d in devices if requested_name.lower() in d["name"].lower()]
    if len(matches) != 1:
        print(f"error: device name not unique/found: {requested_name}", file=sys.stderr)
        raise SystemExit(1)
    d = matches[0]
    print(f"{d['identifier']}\t{d['install_identifier']}\t{d['name']}")
    raise SystemExit(0)

for device in devices:
    if device["available"]:
        print(f"{device['identifier']}\t{device['install_identifier']}\t{device['name']}")
        raise SystemExit(0)

print("error: no available paired physical iPhone/iPad found", file=sys.stderr)
for device in devices:
    print(
        f"  {device['name']} ({device['identifier']}), boot={device['boot']}, tunnel={device['tunnel']}",
        file=sys.stderr,
    )
raise SystemExit(1)
PY
}

if ! selection="$(select_device)"; then
  echo "error: could not select a physical device. Plug in, unlock, Trust, Developer Mode on." >&2
  echo "Or pass --device-id \$(xcrun devicectl list devices) / set ~/.config/cmux/iphone-device-id" >&2
  exit 1
fi

tab=$'\t'
selected_device_id="${selection%%"$tab"*}"
selection_remainder="${selection#*"$tab"}"
selected_device_install_id="${selection_remainder%%"$tab"*}"
selected_device_name="${selection_remainder#*"$tab"}"

echo "==> Installing on $selected_device_name ($selected_device_id)"
xcrun devicectl device install app --device "$selected_device_install_id" "$APP_PATH"

if [[ "$LAUNCH" -eq 1 ]]; then
  if ! xcrun devicectl device process launch --terminate-existing --device "$selected_device_install_id" "$FORK_IOS_BUNDLE_ID" >/dev/null 2>&1; then
    echo "warning: installed but could not launch $FORK_IOS_BUNDLE_ID (device locked? unlock and tap the app)" >&2
  fi
fi

cat <<EOF
==> iOS fork reload succeeded
App path:
  $APP_PATH
Bundle id:
  $FORK_IOS_BUNDLE_ID
Device:
  $selected_device_name ($selected_device_id)

Next:
  1. Mac:  CMUX_SKIP_ZIG_BUILD=1 ./scripts/reload-fork.sh --install
  2. Open "$FORK_APP_NAME" on Mac and "$FORK_IOS_APP_NAME" on the phone
  3. Sign in with the same Stack account on both, then pair (in-app QR / Mobile Connect)

This Release iOS build pairs with the Mac fork's instance tag "default", not
with a Debug --tag build from scripts/reload.sh.
EOF
