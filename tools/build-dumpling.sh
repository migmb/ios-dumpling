#!/usr/bin/env bash
# Build the dumpling (OnePlus 5T / MSM8998) ADT + payload + shim boot image
# from an XNU CI artifact.  See tools/build-fajita.sh for the fajita original.
#
#   XNU_KERNEL=xnu/out/kernel.development.sweet tools/build-dumpling.sh
#
# Host requirements: clang (any), binutils for aarch64-elf
# (brew install aarch64-elf-binutils), cpio, gzip.  mkbootimg falls back to
# tools/mkbootimg.py when the real one is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.local/bin:$PATH"
# shellcheck disable=SC1091
. tools/dumpling.env

BINUTILS=$(dirname "$(command -v aarch64-elf-ld 2>/dev/null || echo /opt/homebrew/opt/aarch64-elf-binutils/bin/ld)")
BINUTILS=${BINUTILS:-/opt/homebrew/opt/aarch64-elf-binutils/bin}
export PATH="$BINUTILS:$PATH"

# Host toolchain: Apple clang emits ELF with the linux triple; binutils does
# the assembling/linking/binarising. Override any of these if you have a real
# aarch64-linux-gnu toolchain.
export CC=${CC:-$(command -v aarch64-linux-gnu-gcc || echo clang)}
export AS=${AS:-$(command -v aarch64-elf-as || echo "")}
export LD=${LD:-$(command -v aarch64-elf-ld || echo "")}
export OBJCOPY=${OBJCOPY:-$(command -v aarch64-elf-objcopy || echo aarch64-linux-gnu-objcopy)}
export NM=${NM:-$(command -v aarch64-elf-nm || echo aarch64-linux-gnu-nm)}
export READELF=${READELF:-$(command -v aarch64-elf-readelf || echo aarch64-linux-gnu-readelf)}

XNU_KERNEL=${XNU_KERNEL:-xnu/out/kernel.development.sweet}
# dumpling v2.1 (qcom,msm-id 0x124/0x20001) = the PVT board DTB; DVT is the
# fallback for early samples.
DTB=${DTB:-$DTB_DEFAULT}
ADT=${ADT:-shim/out/dumpling.adt}
PAYLOAD=${PAYLOAD:-shim/out/payload.bin}
# Phase A: 2 x Cortex-A73 only (the ADT lists exactly those two MPIDRs).
# rd=ufsroot0 needs the port's UFS driver to work on MSM8998; rd=mockfs is the
# first-boot bring-up root. Override with ROOT=ufsroot0 once UFS is verified.
ROOT=${ROOT:-mockfs}
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=2 keepsyms=1 -noprogress nointr_consio=1 rd=$ROOT unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=1 sweetfb_hz=30 sweettouch=0 sweetkeys=0"}

[[ -f "$XNU_KERNEL" ]] || { echo "missing XNU kernel: $XNU_KERNEL" >&2; exit 1; }
[[ -f "$DTB" ]] || { echo "missing stock DTB: $DTB (extract it from the stock boot.img first)" >&2; exit 1; }

MKBOOTIMG=${MKBOOTIMG:-}
if [ -z "$MKBOOTIMG" ]; then
	if command -v mkbootimg >/dev/null 2>&1; then MKBOOTIMG=mkbootimg
	else MKBOOTIMG="$PWD/tools/mkbootimg.py"; fi
fi

mkdir -p shim/out
python3 tools/mkadt.py "$ADT" --highmem --board=dumpling
python3 tools/mkpayload.py "$XNU_KERNEL" "$ADT" "$PAYLOAD" --cmdline "$CMDLINE"
# SHIM_HDR=1 = stock OnePlus layout (header v1, gzipped Image with the DTB
# appended after the gzip stream); the dumpling ABL is the same ABL family.
BOARD=dumpling SHIM_HDR=1 MKBOOTIMG="$MKBOOTIMG" DTB=$(realpath "$DTB") \
	shim/build.sh "$(realpath "$PAYLOAD")"

echo "built: shim/out/shim-boot.img"
