import * as pulumi from "@pulumi/pulumi";
import { NagarePerimeter } from "../src/components/NagarePerimeter";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

async function recordNames(baseDomain: string, retainedDnsName?: string): Promise<{ zone: unknown; records: unknown[]; rules: string[] }> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            return { id: `${args.name}-id`, state: { ...args.inputs, name: args.inputs.name ?? args.name, address: "203.0.113.10" } };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "test", true);
    new NagarePerimeter("nagare", {
        gcpProject: "example-project", region: "us-west1", zone: "us-west1-a", instanceName: "nagare-01",
        machineType: "e2-standard-2", dataDiskSizeGb: 100, baseDomain, retainedDnsName, artifactRegistryId: "nagare", serviceAccountId: "ep150-node",
        backupBucketName: "example-project-nagare-backups", imageBucketName: "example-project-nagare-images",
        enableCdn: false, cdnCertificateMode: "legacy", vmDeletionProtection: true, bootDiskSizeGb: 100, bootDiskType: "pd-balanced",
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await pulumi.runtime.disconnect();
    return {
        zone: resources.find((r) => r.type === "gcp:dns/managedZone:ManagedZone")?.inputs.dnsName,
        records: resources.filter((r) => r.type === "gcp:dns/recordSet:RecordSet").map((r) => r.inputs.name).sort(),
        rules: resources.filter((r) => r.type === "gcp:compute/firewall:Firewall").map((r) => r.name).sort(),
    };
}

// EP-246 D2: once a move to a new base domain has flipped the profile, the zone, its records and every
// firewall rule keep their old values, so a preview with the new base replaces and deletes nothing.
async function retainedAcrossBaseChange(): Promise<void> {
    const before = await recordNames("apps.example.test");
    const after = await recordNames("new.example.org", "apps.example.test");
    if (after.zone !== "apps.example.test." || JSON.stringify(after.records) !== JSON.stringify(["*.apps.example.test.", "apps.example.test."]) || after.rules.length !== 4) {
        throw new Error(`the retained zone lost its old name, records or rules: ${JSON.stringify(after)}`);
    }
    if (JSON.stringify(before) !== JSON.stringify(after)) {
        throw new Error(`a base domain change with a retained zone changed the DNS set or the rules: ${JSON.stringify({ before, after })}`);
    }
}

async function main(): Promise<void> {
    await retainedAcrossBaseChange();
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
