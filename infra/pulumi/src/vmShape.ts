export interface ShapeReader {
    get(key: string): string | undefined;
    getNumber(key: string): number | undefined;
}

export interface VmShape {
    machineType: string;
    bootDiskType: string;
    bootDiskSizeGb: number;
    dataDiskSizeGb: number;
}

// These fallbacks exist only for stacks that predate shape seeding. Every stack
// created by nagarectl init records its own answer. CAUTION: GCE cannot convert
// a boot disk's type in place, so changing bootDiskType against a live VM forces
// an INSTANCE REPLACEMENT.
export const VM_SHAPE_FALLBACKS: VmShape = {
    machineType: "e2-standard-2",
    bootDiskType: "pd-balanced",
    bootDiskSizeGb: 100,
    dataDiskSizeGb: 100,
};

export function resolveVmShape(
    cfg: ShapeReader,
    fallbacks: VmShape = VM_SHAPE_FALLBACKS,
): VmShape {
    return {
        machineType: cfg.get("machineType") ?? fallbacks.machineType,
        bootDiskType: cfg.get("bootDiskType") ?? fallbacks.bootDiskType,
        bootDiskSizeGb: cfg.getNumber("bootDiskSizeGb") ?? fallbacks.bootDiskSizeGb,
        dataDiskSizeGb: cfg.getNumber("dataDiskSizeGb") ?? fallbacks.dataDiskSizeGb,
    };
}
