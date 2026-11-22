#!/bin/bash
# macOS port of scripts/build-go.ps1:
# builds the version-locked Tailscale 1.104.5 / Go 1.27.3 engine.
#
# Note: GOROOT prefers ~/.ohos-go-build/ohos-go (internal APFS disk). Building or
# self-hosting the toolchain from the project volume (/Volumes/nvme11-...) hits
# SIGBUS when freshly written binaries are mmapped for execution, so the toolchain
# bootstrap and all caches live on the internal disk. Prepared source trees
# must match the version lock; the final .so and .h are copied back.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- locate the OHOS Go toolchain (internal-disk build first) ---
go_root="${OHOS_GO_ROOT:-$HOME/.ohos-go-build/ohos-go-1.27.3}"
go_bin="$go_root/bin/go"
if [[ -z "${OHOS_GO_ROOT:-}" && ! -x "$go_bin" ]]; then
  go_root="$project_root/third_party/ohos-go-1.27.3"
  go_bin="$go_root/bin/go"
fi

# --- locate DevEco Studio and its bundled native SDK ---
# (macOS app bundles have no product-info.json; the sdk directory is the marker)
if [[ -n "${DEVECO_STUDIO_HOME:-}" && -d "$DEVECO_STUDIO_HOME/sdk" ]]; then
  deveco_home="$DEVECO_STUDIO_HOME"
elif [[ -d "/Applications/DevEco-Studio.app/Contents/sdk" ]]; then
  deveco_home="/Applications/DevEco-Studio.app/Contents"
else
  echo "DevEco Studio was not found. Set DEVECO_STUDIO_HOME to its installation directory." >&2
  exit 1
fi

sdk_home="${DEVECO_SDK_HOME:-$deveco_home/sdk}"
native_sdk="$sdk_home/default/openharmony/native"
if [[ ! -d "$native_sdk" ]]; then
  echo "HarmonyOS Native SDK was not found at $native_sdk" >&2
  exit 1
fi
PATH="$deveco_home/tools/node/bin:$PATH" node -e '
  const fs = require("node:fs");
  const metadata = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (Number(metadata.apiVersion) !== 26 || metadata.releaseType !== "Release") {
    throw new Error("The native build requires the HarmonyOS API 26 Release SDK.");
  }
' "$native_sdk/oh-uni-package.json"
clang="$native_sdk/llvm/bin/clang"
clangxx="$native_sdk/llvm/bin/clang++"
sysroot="$native_sdk/sysroot"

output_dir="$project_root/native/go_bridge/dist/arm64-v8a"
hap_lib_dir="$project_root/entry/libs/arm64-v8a"
mkdir -p "$output_dir" "$hap_lib_dir"

if [[ ! -x "$go_bin" ]]; then
  echo "The OpenHarmony Go toolchain has not been built yet (missing $go_bin)." >&2
  echo "Prepare the reviewed Go 1.27.3 OHOS port and native/engine-lock.json inputs first." >&2
  exit 1
fi

# Normal builds validate prepared sources; they never patch an arbitrary checkout.
OHOS_GO_ROOT="$go_root" PATH="$deveco_home/tools/node/bin:$PATH" node "$project_root/scripts/verify-engine-inputs.cjs"

# --- build the c-shared library ---
export GOROOT="$go_root"
export PATH="$go_root/bin:$PATH"
export GOOS=openharmony
export GOARCH=arm64
export CGO_ENABLED=1
export GOTOOLCHAIN=local
export GOENV=off
export GOWORK=off
export GOFLAGS=
export GOEXPERIMENT=
# caches on the internal disk: fast, and safe for mmap-heavy go tooling
export GOCACHE="$HOME/.ohos-go-build/gocache-ohos-1.27.3"
export GOMODCACHE="$HOME/.ohos-go-build/gomodcache"
export GOPATH="$HOME/.ohos-go-build/gopath"
# goproxy.cn keeps module downloads working without a global proxy
export GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
export CC="\"$clang\" --target=aarch64-linux-ohos --sysroot=\"$sysroot\" -D__MUSL__ -fstack-protector-strong"
export CXX="\"$clangxx\" --target=aarch64-linux-ohos --sysroot=\"$sysroot\" -D__MUSL__ -fstack-protector-strong"

cd "$project_root/native/go_bridge"
go build -p 2 -mod=readonly -buildmode=c-shared -trimpath -buildvcs=false \
  -ldflags="-extldflags=-Wl,-soname,libtailscale_go.so,--build-id=sha1,-z,relro,-z,now,-z,noexecstack -X tailscale.com/version.longStamp=1.104.5 -X tailscale.com/version.shortStamp=1.104.5" \
  -o "$output_dir/libtailscale_go.so" .

cp -f "$output_dir/libtailscale_go.so" "$hap_lib_dir/libtailscale_go.so"
cp -f "$output_dir/libtailscale_go.h" "$hap_lib_dir/libtailscale_go.h"
echo "Built: $output_dir/libtailscale_go.so"
