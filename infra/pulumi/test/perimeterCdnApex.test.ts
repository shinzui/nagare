import * as pulumi from "@pulumi/pulumi";
import { NagarePerimeter } from "../src/components/NagarePerimeter";

// F43: an inventory context enables the Google CDN as reviewed cloud members but
// keeps the exact apex on the VM (`cdnApex: false`); the default still routes the
// apex through a constructed CDN.

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

async function apexFor(cdnApex: boolean | undefined): Promise<{ apex: unknown; cdn: number }> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? args.name };
            if (args.type === "gcp:compute/address:Address") {
                state.address = "203.0.113.10";
            }
            if (args.type === "gcp:compute/globalAddress:GlobalAddress") {
                state.address = "203.0.113.20";
            }
            if (args.type === "gcp:compute/instance:Instance") {
                state.selfLink = `${args.name}-self-link`;
            }
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", `cdn-apex-${String(cdnApex)}`, true);

    const perimeter = new NagarePerimeter("nagare", {
        gcpProject: "example-project",
        region: "us-west1",
        zone: "us-west1-a",
        instanceName: "nagare-01",
        machineType: "e2-standard-2",
        dataDiskSizeGb: 100,
        baseDomain: "apps.example.test",
        artifactRegistryId: "nagare",
        serviceAccountId: "nagare-node",
        backupBucketName: "example-project-nagare-backups",
        imageBucketName: "example-project-nagare-images",
        imageSelfLink: "image-self-link",
        enableCdn: true,
        cdnApex,
        cdnCertificateMode: "legacy",
        vmDeletionProtection: true,
        bootDiskSizeGb: 100,
        bootDiskType: "pd-balanced",
    });
    await (perimeter.apexIp as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();
    const apex = resources.find((resource) => resource.name === "nagare-apex");
    return {
        apex: apex?.inputs.rrdatas,
        cdn: resources.filter((resource) => resource.name.startsWith("nagare-cdn")).length,
    };
}

async function main(): Promise<void> {
    const kept = await apexFor(false);
    if (kept.cdn === 0) {
        throw new Error("cdnApex false must still construct the CDN");
    }
    if (JSON.stringify(kept.apex) !== JSON.stringify(["203.0.113.10"])) {
        throw new Error(`cdnApex false must keep the apex on the VM: ${JSON.stringify(kept.apex)}`);
    }
    const moved = await apexFor(undefined);
    if (JSON.stringify(moved.apex) !== JSON.stringify(["203.0.113.20"])) {
        throw new Error(`the default must route the apex through the CDN: ${JSON.stringify(moved.apex)}`);
    }
    console.log("ok");
}

main().catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
});
