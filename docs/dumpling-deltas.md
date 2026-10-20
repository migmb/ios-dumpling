# dumpling deltas — what must change from fajita (SDM845) to dumpling (MSM8998)

Verified sources:
- **Live stock DTB**: extracted from this unit's `boot.img` (sha256 in the backup manifest), QCDT-style concatenated DTBs; the matching board blobs are DVT `(8 0 17801 42)` and PVT `(8 0 17801 43)` — confirmed against LineageOS `android_kernel_oneplus_msm8998` `dumpling-v2.1-{dvt,pvt}.dts`. All constants below marked **[DTB]** come from the PVT blob decompiled with `dtc`.
- **Upstream Linux references**: LineageOS `android_kernel_oneplus_msm8998` (`dumpling.dtsi`), `MakrSas/ios-topaz` (ARMv8.0 A73+A53 precedent, branch `topaz`).
- **fajita baseline**: `tools/fajita.env`, `PORTING.md`, diff `sweet/main..fajita main`.

## 1. CPU / machine config — the biggest delta

| Item | fajita (SDM845) | dumpling (MSM8998) | Consequence |
|---|---|---|---|
| Cores | 4×A55 + 4×A75, ARMv8.2 | **2×A73 + 4×A53, ARMv8.0** [DTB] | sweet's "ARMv8.2 free ride" is gone |
| MPIDR | A55 0x000–0x300, A75 0x400–0x700 | **A53 0x000–0x300, A73 0x400–0x500** (cluster<<8) [DTB] | `mkadt.py` cluster split + freq table |
| LSE atomics | native | **A73 yes / A53 no** | mixed-cluster atomics problem |
| PAN | available | **absent on both** | needs topaz patch 0081 half |
| 16K pages | both clusters | **A73 yes (LPA) / A53 no** | same situation as topaz |
| Boot CPU | MPIDR 0 | topaz boots gold MPIDR 0x100; **dumpling gold is 0x400/0x500** | SweetCPU boot-CPU expectation must take the ADT-listed boot MPIDR (0x400) |

**Recommended strategy (mirrors `MakrSas/ios-topaz`, patches `0081-topaz-armv8.0-no-lse-no-pan`, `0082-topaz-boot-on-gold-cpu`):**
- Phase A: **gold-only (2×A73), 16K pages, `-mcpu=cortex-a73`** — dumpling's A73 has native LSE, so topaz's LDAXR/STXR emulation of `casa` etc. is *not* needed for phase A; only the PAN-off and machine-flags parts of 0081 apply. Keep the SWEET board config name (platform expert matches `xiaomi,sweet` compatible).
- Phase B (optional, later): add A53 silver cores → forces **4K pages everywhere** + LSE runtime fallback (A53 lacks LSE; ld/st atomics only). This is a pmap rebuild decision; do not block bring-up on it.
- Files: `xnu/patches/0004` (machine config: CPU count 6→2 for phase A, ARMv8.0 flags in `makedefs/MakeInc.def`), `0082`-equivalent boot-CPU patch in `iokit/Kernel/arm/SweetCPU.cpp`, `0018` boot CPU driver.

## 2. Shim constants (`shim/`, `tools/fajita.env` → new `tools/dumpling.env`)

| Constant | fajita | dumpling | Source |
|---|---|---|---|
| Splash framebuffer | 0x9d400000 | **0x9d600000, size 0x02400000** (`cont_splash_mem reg = <0x9d600000 0x00 0x2400000>`) | [DTB] |
| FB geometry | 1080×2340 stride 4320 | **1080×2160** (panel coords [DTB]/`dumpling.dtsi`); stride/offset runtime-verify | `synaptics,display-coords = <1080 2160>` |
| GICD | 0x17a00000 | **0x17a00000** (unchanged) | [DTB] `interrupt-controller@17a00000` |
| GICR | 0x17a60000 stride 0x20000 | **0x17b00000, contiguous stride 0x10000** (`reg = <0x17a00000 0x10000 0x17b00000 0x100000>`) | [DTB] — `shim` GIC init MUST change |
| UFS host | 0x1d84000 | **0x1da4000** (`reg = <0x1da4000 0x2500>`, `qcom,ufshc`) | [DTB] |
| UFS PHY | 0x1d87000 | **0x1da7000** (`qcom,ufs-phy-qmp-v3`, `reg = <0x1da7000 0xda8>`) | [DTB] |
| PS_HOLD | 0x0c264000 | **0x010ac000** (`qcom,pshold reg = <0x10ac000 0x04 0x1fd3000 0x04>`; TCSR boot-misc-detect 0x1fd3000) | [DTB] |
| IMEM restart reason | 0x146bf65c | **0x1480f65c** (MSM8998 IMEM base 0x14800000 + 0x65c; verify against live boot behavior) | msm8998 downstream convention |
| RAM high bank | 0x100000000 + 0x17c8a0000 (measured) | **read live FDT** (6 or 8 GB LPDDR4X; DTB has no memory nodes — ABL supplies them) | shim prints live FDT mem nodes on no-payload boot |
| PSCI | smc | **`arm,psci-1.0`, method = "smc"** | [DTB] `psci` node |
| Timer | virtual timer INTID 19 | same expectation (GICv3 Group-1) — verify on first boot | patch 0017 pattern |

## 3. Touch + I2C host (`xnu/patches/0060/0062/0063/0071`, shim→kernel drivers)

- **Bus**: fajita uses GENI/QUPv3 SE12 @ 0xa90000. dumpling is **classic (pre-GENI) QUP**: touch sits on `i2c@c179000` (i2c5 alias) at address **0x20** [DTB `synaptics@20`]. The GENI SE FIFO/packing code (patch 0063) does not apply; a classic QUP driver (QUP_GS: `QUP_XBAR`/`I2C_M0` style, see Linux `i2c-qup.c`) is required — this is the single largest driver rewrite in the port.
- **Controller**: downstream DT calls it `synaptics,s3320` + `synaptics,dsx` [DTB]; `dumpling.dtsi` rails: vdd 1.808 V, avdd 3.008 V; reset GPIO **89**, IRQ GPIO **125** [DTB `dumpling.dtsi` lines 685-686]. Treat protocol as RMI4 F01/F12 (read chip ID at runtime, same open question as fajita #4).
- Fingerprint Goodix on i2c4 (`c178000`) — out of scope (no SEP anyway).

## 4. Keys (`xnu/patches/0060` PMIC path)

- Power: **PM8998 SPMI SID 0, PON block at 0x800** (`kpdpwr`/`resin`, `linux,code 0x74/0x72`) [DTB `qcom,power-on@800`]. fajita's PMIC PON code applies with SID/reg tweaks.
- SPMI controller (pmic-arb) reg layout differs from SDM845's: `core 0x800f000/0x1000, chns 0x8400000/1M, obsrvr 0x9400000/1M, intr 0xa400000/0x220000, cnfg 0x800a000/0x3000`, `qcom,ee=0 channel=0` [DTB `qcom,spmi@800f000`]. fajita/sweet SPMI bring-up must use these windows.
- Volume keys: not visible as gpio-keys in the DTB — **runtime discovery** (PM8998 GPIO pins via `qcom,qpnp-pin`, or the tri-state key path on TLMM gpio 42/26/40). Task 5.2 answers this on-device.
- Tri-state key: `oneplus,tri-state-key`, TLMM gpios 42/26/40 [DTB] — bonus HID consumer key later.

## 5. Display

- Panel: **Samsung S6E3FA3, 1080p DSI** — DTB carries both cmd-mode and video-mode variants; `hw-config = "single_dsi"` (`dumpling.dtsi` L716). Video mode + `splash-enabled` + cont_splash_mem strongly suggest ABL continuous splash reaches the shim (fajita open question #1 equivalent — verify with shim test pattern first).
- Patches to touch: `0010`/`0012` (early FB physical base → 0x9d600000, height 2160), `0061` (native panel height 2160; iPhone X 1125×2436 presentation stays).
- MSM8998 MDSS register base is the same 0x6400000 MMSS region family; only needed if splash is lost.

## 6. UFS (`shim/ufs.c`, patches 0028-0034, 0069)

- Host base/PHY differ (see table). MSM8998 UFSHCI 2.1 + QMP v3 PHY: sweet's driver targets UFS 3.0 on SM7150, fajita runs 2.1 on SDM845 — the fajita variant is the starting point; expect clock/GDSC differences (MSM8998 uses RPM-regulated clocks, no RPMh). ABL host hand-off state: verify with the read-only UFS probe on no-payload shim boot (fajita's first-hardware-test recipe applies unchanged).
- Crypto (ufshc `ufs-qcom-crypto` phandle present [DTB]): keep ICE disabled as upstream does.

## 7. Boot image / DTB extraction quirks (`tools/extract-dtb.py`, `shim/build.sh`)

- dumpling stock `boot.img` (LineageOS 22.2 20261013 and stock alike): **header v1, page_size 256**, kernel+ramdisk then **concatenated big-endian DTBs** in a ~7.3 MB region after the ramdisk (13 DTBs, `d00dfeed` per blob, blob size = be32 at +4). fajita's `extract-dtb.py` assumes DTBs appended to the *kernel* with v1 header v2-style 4K pages — adapt offsets/format (small change).
- Board selection: this unit is **v2.1** (`qcom,msm-id` check on the PVT blob) → use the PVT DTB (`(8 0 17801 43)`); DVT kept as fallback.
- **No A/B slots** (single `boot`, `getvar current-slot` absent on device): the sweet-style `fastboot boot shim-boot.img` path is available — fajita had to flash `boot_b` because OOS 10/11 disabled `fastboot boot`; dumpling's OOS 9/10 ABL supports it. **Quirk observed 2026-10-20**: `fastboot boot <LineageOS recovery.img>` returned `OKAY/Booting OKAY` but the device then vanished from USB (no adb, no fastboot, no USB enumeration) — power-cycle recovered it. Treat `fastboot boot` as best-effort on this ABL; keep "flash shim to `boot`, keep stock `boot.img` backup for rollback" as the fallback path (backup already taken, see evidence/backup-manifest.md).

## 8. Files fajita touched that need dumpling values (completeness check vs `git diff sweet/main..fajita main`)

| File | fajita change | dumpling action |
|---|---|---|
| `shim/console.h` | FB 0x9d400000, 1080×2340 | 0x9d600000, 1080×2160 |
| `shim/mmu.{c,h}` | FB block mapping | same block size; base per new FB |
| `shim/shim.c` | IMEM 0x146bf65c | 0x1480f65c; GICR 0x17b00000/contiguous |
| `shim/ufs.c` | host addr consts | 0x1da4000/0x1da7000 |
| `shim/build.sh` | DTB/MKBOOTIMG overrides | same pattern; DTB = dumpling PVT |
| `shim/fdt.{c,h}` (new in fajita) | live FDT parsing | reuse as-is |
| `tools/fajita.env` | consts | new `tools/dumpling.env` (this doc's tables) |
| `tools/build-fajita.sh` | payload build | `tools/build-dumpling.sh` |
| `tools/extract-dtb.py` | appended-to-kernel DTBs | concatenated-after-ramdisk variant (§7) |
| `tools/mkadt.py` | FB/CPU/kryo385 consts | 2×A73 (phase A), MPIDR 0x400/0x500, msm8998 compatible, new regs |
| `xnu/patches/0004` | SWEET cfg reuse | ARMv8.0 machine flags (§1) |
| `xnu/patches/0010`,`0012` | FB base/height | §5 values |
| `xnu/patches/0061` | panel height | 2160 |
| `xnu/patches/0058` | HID userland match | unchanged |
| `xnu/patches/0082` (fajita) | boot markers | reuse; adjust CPU count |
| `.github/workflows/xnu.yml` | MACHINE_CONFIG default SWEET | keep SWEET name; add DUMPLING flags row or reuse SWEET with new flags |

## 9. Runtime unknowns (answer on-device, do not guess)

1. Live FDT memory map (high bank size) — shim no-payload boot prints it.
2. Splash framebuffer geometry/offset within 0x9d600000 (width/stride) — test pattern.
3. Volume-key wiring (PM8998 GPIO vs tri-state) — SPMI reads during 5.2.
4. Touch IC identity via RMI4 F01 read after classic-QUP works.
5. UFS link state after ABL hand-off — read-only probe.
6. Whether `fastboot boot` of our shim survives the ABL quirk (§7) — else flash-to-boot fallback.
