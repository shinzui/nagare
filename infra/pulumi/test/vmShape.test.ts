import { resolveVmShape, ShapeReader, VmShape, VM_SHAPE_FALLBACKS } from "../src/vmShape";

class ObjectReader implements ShapeReader {
    constructor(private readonly values: Record<string, string | number>) {}

    get(key: string): string | undefined {
        const value = this.values[key];
        return typeof value === "string" ? value : undefined;
    }

    getNumber(key: string): number | undefined {
        const value = this.values[key];
        return typeof value === "number" ? value : undefined;
    }
}

function assertShape(label: string, actual: VmShape, expected: VmShape): void {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

const seeded: VmShape = {
    machineType: "e2-standard-4",
    bootDiskType: "pd-ssd",
    bootDiskSizeGb: 200,
    dataDiskSizeGb: 500,
};
const deliberatelyDifferentFallbacks: VmShape = {
    machineType: "e2-standard-8",
    bootDiskType: "pd-standard",
    bootDiskSizeGb: 10,
    dataDiskSizeGb: 10,
};

assertShape(
    "seeded values ignore changed program fallbacks",
    resolveVmShape(
        new ObjectReader({
            machineType: seeded.machineType,
            bootDiskType: seeded.bootDiskType,
            bootDiskSizeGb: seeded.bootDiskSizeGb,
            dataDiskSizeGb: seeded.dataDiskSizeGb,
        }),
        deliberatelyDifferentFallbacks,
    ),
    seeded,
);
assertShape("an empty reader uses all fallbacks", resolveVmShape(new ObjectReader({})), VM_SHAPE_FALLBACKS);
assertShape(
    "a partial reader mixes seeded values and fallbacks",
    resolveVmShape(new ObjectReader({ machineType: "n2-standard-4", dataDiskSizeGb: 250 })),
    { ...VM_SHAPE_FALLBACKS, machineType: "n2-standard-4", dataDiskSizeGb: 250 },
);

console.log("ok");
