import * as pulumi from "@pulumi/pulumi";
import { NagareAdminApiReader, inventoryReadCondition } from "../src/components/NagareAdminApiReader";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

// EP-196: the admin API reader is a dedicated account with exact,
// read-only grants, and nothing at all when disabled.
async function main(): Promise<void> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? `projects/example-project/roles/${String(args.inputs.roleId ?? args.name)}` };
            if (args.type === "gcp:serviceaccount/account:Account") state.email = `${String(args.inputs.accountId)}@example-project.iam.gserviceaccount.com`;
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => ({ ...args.inputs, number: "123456789012" }),
    }, "nagare", "intranet", true);

    new NagareAdminApiReader("disabled-reader", {
        enabled: false,
        gcpProject: "example-project",
        accountId: "nagare-admin-api",
        stateBucket: "example-project-nagare-pulumi-state",
        inventoryPrefix: "nagare/intranet/inventory",
    });
    const enabled = new NagareAdminApiReader("reader", {
        enabled: true,
        gcpProject: "example-project",
        accountId: "nagare-admin-api",
        stateBucket: "example-project-nagare-pulumi-state",
        inventoryPrefix: "nagare/intranet/inventory/",
    });
    const number = await (enabled.projectNumber as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();

    const gcp = resources.filter((resource) => resource.type.startsWith("gcp:"));
    assert(!gcp.some((resource) => resource.name.startsWith("disabled-reader")), "a disabled reader created GCP resources");
    const types = gcp.map((resource) => resource.type).sort();
    assert(JSON.stringify(types) === JSON.stringify([
        "gcp:projects/iAMCustomRole:IAMCustomRole",
        "gcp:projects/iAMCustomRole:IAMCustomRole",
        "gcp:serviceaccount/account:Account",
        "gcp:storage/bucketIAMMember:BucketIAMMember",
        "gcp:storage/bucketIAMMember:BucketIAMMember",
    ]), `unexpected reader resources: ${JSON.stringify(types)}`);

    const permissions = gcp
        .filter((resource) => resource.type === "gcp:projects/iAMCustomRole:IAMCustomRole")
        .map((resource) => JSON.stringify(resource.inputs.permissions))
        .sort();
    assert(JSON.stringify(permissions) === JSON.stringify(['["storage.buckets.get"]', '["storage.objects.get"]']), `the reader has more than read permissions: ${permissions}`);

    const members = gcp.filter((resource) => resource.type === "gcp:storage/bucketIAMMember:BucketIAMMember");
    const conditioned = members.find((resource) => resource.inputs.condition !== undefined);
    const plain = members.find((resource) => resource.inputs.condition === undefined);
    assert(conditioned !== undefined && plain !== undefined, "the reader needs one conditioned object grant and one bucket metadata grant");
    const expression = (conditioned!.inputs.condition as { expression: string }).expression;
    const root = "projects/_/buckets/example-project-nagare-pulumi-state/objects/nagare/intranet/inventory";
    assert(expression === inventoryReadCondition("example-project-nagare-pulumi-state", "nagare/intranet/inventory"), "the condition is not the shared expression");
    assert(expression.includes(`resource.name == "${root}/head.json"`), "the head is not readable");
    assert(expression.includes(`resource.name == "${root}/format.json"`), "the format is not readable");
    assert(expression.includes(`resource.name.startsWith("${root}/scopes/")`), "the scopes are not readable");
    assert(expression.includes(`resource.name == "${root}/versions/latest.json"`), "the platform-versions snapshot is not readable");
    assert(!expression.includes(`startsWith("${root}/versions`), "the condition admits more than the one versions snapshot");
    for (const hidden of ["native/", "reviews/", "journal/"]) {
        assert(!expression.includes(`${root}/${hidden}`), `the condition admits ${hidden}`);
    }
    assert(!expression.includes(`startsWith("${root}/")`), "the condition admits the whole inventory, including reviews and native payloads");
    assert(String(conditioned!.inputs.role).endsWith("nagareInventoryObjectReader"), "the object grant has the wrong role");
    assert(String(plain!.inputs.role).endsWith("nagareInventoryBucketReader"), "the unconditioned grant is not metadata-only");
    assert(number === "123456789012", "the project number is not exported");
    process.stdout.write("admin API reader resources: OK\n");
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

main().catch((error) => {
    process.stderr.write(`${String(error)}\n`);
    process.exit(1);
});
