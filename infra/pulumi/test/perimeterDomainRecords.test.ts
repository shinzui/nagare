import * as pulumi from "@pulumi/pulumi";
import { NagarePerimeter } from "../src/components/NagarePerimeter";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

async function main(): Promise<void> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = {
                ...args.inputs,
                name: args.inputs.name ?? args.name,
            };
            if (args.type === "gcp:compute/address:Address") {
                state.address = "203.0.113.10";
            }
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "test", true);

    const perimeter = new NagarePerimeter("nagare", {
        gcpProject: "example-project",
        region: "us-west1",
        zone: "us-west1-a",
        instanceName: "nagare-01",
        machineType: "e2-standard-2",
        dataDiskSizeGb: 100,
        baseDomain: "apps.example.test",
        artifactRegistryId: "nagare",
        serviceAccountId: "ep150-node",
        backupBucketName: "example-project-nagare-backups",
        imageBucketName: "example-project-nagare-images",
        enableCdn: false,
        cdnCertificateMode: "legacy",
        vmDeletionProtection: true,
        bootDiskSizeGb: 100,
        bootDiskType: "pd-balanced",
    });

    const apexIp = await (perimeter.apexIp as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();
    const records = resources.filter((resource) => resource.type === "gcp:dns/recordSet:RecordSet");
    const serviceAccount = resources.find((resource) => resource.type === "gcp:serviceaccount/account:Account");
    if (serviceAccount?.inputs.accountId !== "ep150-node") {
        throw new Error(`service account override was not used: ${JSON.stringify(serviceAccount)}`);
    }
    if (records.length !== 2) {
        throw new Error(`expected two DNS records, got ${records.length}`);
    }

    const wildcard = records.find((record) => record.name === "nagare-wildcard");
    const apex = records.find((record) => record.name === "nagare-apex");
    if (wildcard?.inputs.name !== "*.apps.example.test.") {
        throw new Error(`unexpected wildcard record: ${JSON.stringify(wildcard)}`);
    }
    if (apex?.inputs.name !== "apps.example.test.") {
        throw new Error(`unexpected apex record: ${JSON.stringify(apex)}`);
    }
    if (JSON.stringify(wildcard.inputs.rrdatas) !== JSON.stringify(["203.0.113.10"])) {
        throw new Error(`wildcard does not target publicIp: ${JSON.stringify(wildcard.inputs)}`);
    }
    if (JSON.stringify(apex.inputs.rrdatas) !== JSON.stringify([apexIp])) {
        throw new Error(`apex does not target apexIp: ${JSON.stringify(apex.inputs)}`);
    }

    console.log("ok");
}

main().catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
});
