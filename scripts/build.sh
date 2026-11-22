#!/bin/bash
# macOS port of scripts/build.ps1: wires DevEco's hvigor into the project,
# builds the Go core, then assembles a Debug HAP. Usage: scripts/build.sh [default]
set -euo pipefail

Product="${1:-default}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -gt 1 || "$Product" != default ]]; then
  echo 'This macOS entry supports only the default Debug product.' >&2
  echo 'For Release, confirm the release review and changelog, then use scripts/build.ps1 -Product release on Windows.' >&2
  exit 1
fi
cd "$ROOT"
[[ -f build-profile.json5 ]] || {
  echo 'Copy build-profile.example.json5 to build-profile.json5 and configure your SDK first.' >&2
  exit 1
}

if [[ -n "${DEVECO_STUDIO_HOME:-}" && -d "$DEVECO_STUDIO_HOME/sdk" ]]; then
  deveco_home="$DEVECO_STUDIO_HOME"
elif [[ -d "/Applications/DevEco-Studio.app/Contents/sdk" ]]; then
  deveco_home="/Applications/DevEco-Studio.app/Contents"
else
  echo "DevEco Studio was not found. Set DEVECO_STUDIO_HOME." >&2
  exit 1
fi

hvigor_home="$deveco_home/tools/hvigor/hvigor"
hvigor="$hvigor_home/bin/hvigor.js"
hvigor_wrapper="$deveco_home/tools/hvigor/bin/hvigorw.js"
# macOS JBR layout differs from Windows
java_home="$deveco_home/jbr/Contents/Home"
node_bin="$deveco_home/tools/node/bin"
sdk_home="${DEVECO_SDK_HOME:-$deveco_home/sdk}"

[[ -f "$hvigor_wrapper" || -f "$hvigor" ]] || { echo "DevEco Hvigor was not found under $deveco_home" >&2; exit 1; }

# symlinks stand in for the NTFS junctions used by the PowerShell script
tooling_scope="$ROOT/.tooling/node_modules/@ohos"
mkdir -p "$tooling_scope"
[[ -e "$tooling_scope/hvigor" ]] || ln -s "$hvigor_home" "$tooling_scope/hvigor"
[[ -e "$tooling_scope/hvigor-ohos-plugin" ]] || ln -s "$deveco_home/tools/hvigor/hvigor-ohos-plugin" "$tooling_scope/hvigor-ohos-plugin"

export JAVA_HOME="$java_home"
export PATH="$java_home/bin:$node_bin:$PATH"
export DEVECO_SDK_HOME="$sdk_home"
export OHOS_SDK_HOME="$sdk_home"
export HVIGOR_USER_HOME="$ROOT/.hvigor-user"
export NODE_PATH="$ROOT/.tooling/node_modules:$hvigor_home/node_modules:$deveco_home/tools/hvigor/hvigor-ohos-plugin/node_modules"

node "$ROOT/scripts/verify-sdk-baseline.cjs" "$ROOT/build-profile.json5"

"$ROOT/scripts/build-go.sh"

if [[ -f "$hvigor_wrapper" ]]; then
  # Match the verified Windows flow: the wrapper resolves the project's engine.
  unset NODE_PATH
  hvigor="$hvigor_wrapper"
fi
node "$hvigor" --mode module -p module=entry@default -p product="$Product" \
  -p buildMode=debug -p debuggable=true assembleHap --no-daemon

printf 'HAP output: %s\n' "$ROOT/entry/build/default/outputs/default/"
