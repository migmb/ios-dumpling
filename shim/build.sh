#!/bin/bash
# Build the shim and wrap it in a boot.img v2.
# Verify the header fields/offsets against the stock OnePlus boot.img before flashing.
# BOARD=fajita (default) or dumpling selects shim/board.h; BOARD=dumpling also
# switches the default DTB. CC/OBJCOPY/NM/OBJDUMP override the toolchain
# (host clang -target aarch64 works: brew install aarch64-elf-binutils).
set -euo pipefail
cd "$(dirname "$0")"

BOARD=${BOARD:-fajita}
case "$BOARD" in
	dumpling) BOARD_FLAG=-DBOARD_DUMPLING; BOARD_DTB=../dtb/boot_unpacked/dumpling_pvt.dtb ;;
	fajita)   BOARD_FLAG=-DBOARD_FAJITA;   BOARD_DTB=../dtb/boot_unpacked/fajita2.dtb ;;
	*) echo "BOARD must be fajita or dumpling" >&2; exit 1 ;;
esac

MKBOOTIMG=${MKBOOTIMG:-mkbootimg}
# fajita2 = SDM845 v2.1 (the revision this phone reports); fajita0 is v2.
# dumpling_pvt = dumpling v2.1 PVT (this unit); see tools/dumpling.env.
DTB=${DTB:-$BOARD_DTB}
# 2 (default): header v2 with a real dtb section. 1: the stock fajita layout,
# header v1 with the DTB appended to the kernel blob (no dtb section), which
# the SDM845 ABL is known to accept.
HDR=${SHIM_HDR:-2}
CC=${CC:-aarch64-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-aarch64-linux-gnu-objcopy}
NM=${NM:-aarch64-linux-gnu-nm}
READELF=${READELF:-aarch64-linux-gnu-readelf}
LD=${LD:-}
# Apple clang's integrated assembler rejects some GNU-style fixups (adr to
# linker symbols); assemble .S with binutils when clang is the compiler.
AS=${AS:-}
if [ -z "$AS" ]; then
	case "$CC" in *clang*) AS=aarch64-elf-as ;; *) AS="$CC" ;; esac
fi
# Apple clang defaults to arm64-apple-darwin (Mach-O); force the ELF triple.
case "$CC" in
	*clang*) case "$CC" in *aarch64*|*arm64*linux*) : ;; *) CC="$CC -target aarch64-unknown-linux-gnu" ;; esac ;;
esac
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-jump-tables -Wall -Wextra $BOARD_FLAG"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	if [ "${f##*.}" = S ]; then $AS -c $f -o out/${f%.*}.o; else $CC $CFLAGS -c $f -o out/${f%.*}.o; fi
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
if [ -n "$LD" ]; then
	$LD -static -T shim.ld --build-id=none --no-warn-rwx-segments -N \
		out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
else
	$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
		out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
fi
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$($NM out/shim.elf | awk '$3=="_end"{print $1}' | { read h && printf 0x%x "$((0x$h))"; })
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
if [ "$HDR" = 1 ]; then
	# Stock layout: gzipped Image with the DTB appended right after the gzip
	# stream (both stock fajita boot images start with 1f 8b at the kernel
	# offset -> Image.gz-dtb), header v1 and no dtb section. ABL gunzips the
	# kernel and puts the DTB directly after the decompressed image, which is
	# exactly where fdt_locate() looks (_end).
	gzip -9 -n -c out/Image > out/Image.gz
	cat out/Image.gz "$DTB" > out/Image.gz-dtb
	"$MKBOOTIMG" --header_version 1 --kernel out/Image.gz-dtb --ramdisk out/ramdisk.bin \
		--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
else
	"$MKBOOTIMG" --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
		--dtb "$DTB" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
		--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
		--os_version 17.0.0 --os_patch_level 2035-06 \
		--cmdline "console=null" -o out/shim-boot.img
fi
# Host render of the console layout.
gcc -O1 -Wall $BOARD_FLAG -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
