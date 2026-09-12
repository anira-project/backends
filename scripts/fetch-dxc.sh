#!/usr/bin/env bash
# Fetch Microsoft's DirectX Shader Compiler redistributables (dxcompiler.dll + dxil.dll) into a
# package lib dir. Dawn's D3D12 backend loads both at device creation ("DynamicLib.Open:
# dxil.dll" otherwise), so every Windows -gpu package whose WebGPU path runs on Dawn/D3D12 —
# LiteRT's prebuilt WebGpu accelerator, ONNX Runtime's WebGPU EP — must ship them next to the
# library that loads them. Pinned to a stable DXC release (not a Shader Model preview) with the
# GitHub-published sha256; the MS + LLVM licenses ride along as DXC-LICENSE-*.txt.
#
# Usage: fetch-dxc.sh <arch> <dest-dir>      <arch> = x86_64 | arm64
set -euo pipefail
ARCH="${1:?arch}"; DEST="${2:?dest dir}"
DXC_VER="v1.9.2607"
DXC_ZIP="dxc_2026_07_29.zip"
DXC_SHA256="a1dfb116ba3eeae6a1582291b53a8e7bf65ad760676bd3194685c8f7367cd241"
case "$ARCH" in x86_64) sub=x64 ;; arm64) sub=arm64 ;; *) echo "ERROR: fetch-dxc: arch must be x86_64|arm64 (got '$ARCH')"; exit 1 ;; esac

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$DXC_ZIP" "https://github.com/microsoft/DirectXShaderCompiler/releases/download/${DXC_VER}/${DXC_ZIP}"
got="$( (shasum -a 256 "$tmp/$DXC_ZIP" 2>/dev/null || sha256sum "$tmp/$DXC_ZIP") | cut -d' ' -f1)"
[ "$got" = "$DXC_SHA256" ] || { echo "ERROR: DXC $DXC_ZIP sha256 $got != pinned $DXC_SHA256"; exit 1; }
( cd "$tmp" && cmake -E tar xf "$DXC_ZIP" )   # libarchive: on every runner, handles the zip's backslash paths
mkdir -p "$DEST"
for f in dxcompiler.dll dxil.dll; do
  src="$(find "$tmp/bin/$sub" -name "$f" -type f | head -1)"
  [ -n "$src" ] || { echo "ERROR: $f for $sub not in $DXC_ZIP"; exit 1; }
  cp "$src" "$DEST/$f"
done
cp "$tmp/LICENSE-MS.txt" "$DEST/DXC-LICENSE-MS.txt"
cp "$tmp/LICENSE-LLVM.txt" "$DEST/DXC-LICENSE-LLVM.txt"
echo "staged DXC $DXC_VER ($sub): dxcompiler.dll dxil.dll -> $DEST"
