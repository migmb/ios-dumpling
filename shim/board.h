/*
 * Board constants for the shim. Selected with -DBOARD_FAJITA / -DBOARD_DUMPLING
 * (shim/build.sh sets BOARD=dumpling|fajita). Values marked [DTB] were read
 * from this unit's stock boot.img DTB (see docs/dumpling-deltas.md).
 */
#ifndef SHIM_BOARD_H
#define SHIM_BOARD_H

#if defined(BOARD_DUMPLING)

/* OnePlus 5T (dumpling), Qualcomm MSM8998. */

#define FB_BASE		0x9d600000UL	/* cont_splash_mem reg = <0x9d600000 0x2400000> [DTB] */
#define FB_W		1080
#define FB_H		2160			/* panel coords [DTB]; verify offset/stride on device */
#define FB_STRIDE	(FB_W * 4)

#define GICD_BASE	0x17a00000UL
#define GICR_BASE	0x17b00000UL	/* gic-v3 reg: <dist 0x17a00000 0x10000> <redist 0x17b00000 0x100000> [DTB] */
#define GICR_SIZE	0x100000UL
#define GICR_PE_SIZE	0x10000UL	/* MSM8998: contiguous 64K redistributor regions */

#define UFS_BASE	0x01da4000UL	/* qcom,ufshc reg = <0x1da4000 0x2500> [DTB] */

#define PSHOLD			0x010ac000UL	/* qcom,pshold pshold-base [DTB] */
#define IMEM_RESTART_REASON	0x1480f65cUL	/* msm8998 IMEM base 0x14800000 + restart_reason@0x65c */

/*
 * Kryo 280: 4x Cortex-A53 (silver, MPIDR Aff1=0) + 2x Cortex-A73 (gold,
 * Aff1=1) [DTB cpu@0..3, cpu@100..101].  The ADT we hand to xnu lists the
 * gold cores only for now (16K pages), so the shim must not PSCI-on the
 * silvers: NR_CPUS is the number of PSCI-on-able secondaries it probes.
 */
#define CPU_MPIDR_LIST		{ 0x000, 0x100, 0x200, 0x300, 0x400, 0x500 }
#define CPU_ON_MPIDR(idx)	cpu_mpidr[idx]
#define CPU_ON_DOMAIN(idx)	(0x8000u + (idx))	/* QCOM_PSD_STATE(aff) layout */
extern const uint32_t cpu_mpidr[];
#define NR_CPUS			6

#define PSCI_CPU_ON_FN		0xc4000003u	/* smc-conduit PSCI 1.0 [DTB psci] */

#elif defined(BOARD_FAJITA)

/* OnePlus 6T (fajita), Qualcomm SDM845. */

#define FB_BASE		0x9d400000UL
#define FB_W		1080
#define FB_H		2340
#define FB_STRIDE	(FB_W * 4)

#define GICD_BASE	0x17a00000UL
#define GICR_BASE	0x17a60000UL
#define GICR_SIZE	0x100000UL
#define GICR_PE_SIZE	0x20000UL

#define UFS_BASE	0x01d84000UL

#define PSHOLD			0x0c264000UL
#define IMEM_RESTART_REASON	0x146bf65cUL

/* Kryo 385: 4x A55 + 4x A75, MPIDR = core << 8. */
#define CPU_MPIDR_LIST		{ 0x000, 0x100, 0x200, 0x300, 0x400, 0x500, 0x600, 0x700 }
#define CPU_ON_MPIDR(idx)	((uint64_t)(idx) << 8)
#define CPU_ON_DOMAIN(idx)	(0x8000u + (idx))
extern const uint32_t cpu_mpidr[];
#define NR_CPUS			8

#define PSCI_CPU_ON_FN		0xc4000003u

#else
#error "define BOARD_FAJITA or BOARD_DUMPLING"
#endif

#define FB_PHYS		FB_BASE
#define FB_BLOCK	(FB_BASE & ~0x1ffffffUL)	/* 32 MiB block containing the splash */

#endif /* SHIM_BOARD_H */
