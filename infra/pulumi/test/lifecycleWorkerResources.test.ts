import * as pulumi from "@pulumi/pulumi";
import {
    NagareLifecycleWorker,
    lifecycleFeedWriteCondition,
    lifecycleInventoryReadCondition,
    lifecyclePrefix,
    lifecycleWorkerRoles,
} from "../src/components/NagareLifecycleWorker";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

// Predefined roles that grant no object or bucket write: Object Viewer
// (objects get/list, folder and managed-folder get/list) and Bucket Viewer
// (buckets get/list). Any other role can write.
const readOnlyRoles = new Set(["roles/storage.objectViewer", "roles/storage.bucketViewer"]);

// EP-235 M2: the lifecycle worker is a dedicated account that reads the
// inventory and the backups and writes only the lifecycle feed, and nothing
// at all when disabled.
async function main(): Promise<void> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs };
            if (args.type === "gcp:serviceaccount/account:Account") state.email = `${String(args.inputs.accountId)}@example-project.iam.gserviceaccount.com`;
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "intranet", true);

    new NagareLifecycleWorker("disabled-worker", {
        enabled: false,
        gcpProject: "example-project",
        accountId: "nagare-events",
        stateBucket: "example-project-nagare-pulumi-state",
        inventoryPrefix: "nagare/intranet/inventory",
        backupBucket: "example-project-nagare-backups",
    });
    const enabled = new NagareLifecycleWorker("worker", {
        enabled: true,
        gcpProject: "example-project",
        accountId: "nagare-events",
        stateBucket: "example-project-nagare-pulumi-state",
        inventoryPrefix: "nagare/intranet/inventory/",
        backupBucket: "example-project-nagare-backups",
    });
    const email = await (enabled.email as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();

    const gcp = resources.filter((resource) => resource.type.startsWith("gcp:"));
    assert(!gcp.some((resource) => resource.name.startsWith("disabled-worker")), "a disabled worker created GCP resources");
    assert(email === "nagare-events@example-project.iam.gserviceaccount.com", "the account is not nagare-events");
    const types = gcp.map((resource) => resource.type).sort();
    assert(JSON.stringify(types) === JSON.stringify([
        "gcp:serviceaccount/account:Account",
        ...Array(5).fill("gcp:storage/bucketIAMMember:BucketIAMMember"),
    ]), `unexpected worker resources: ${JSON.stringify(types)}`);
    // No custom role (EP-248 D6), no project-level grant, no key in Pulumi state.
    assert(!gcp.some((resource) => resource.type.startsWith("gcp:projects/")), "the worker declares a custom role or a project-level grant");
    assert(!gcp.some((resource) => resource.type.includes("serviceAccountKey") || resource.type.includes("hmacKey")), "a key would put secret material in Pulumi state");

    const members = new Map(gcp
        .filter((resource) => resource.type === "gcp:storage/bucketIAMMember:BucketIAMMember")
        .map((resource) => [resource.name, resource]));
    assert(JSON.stringify([...members.keys()].sort()) === JSON.stringify(
        ["worker-backups", "worker-backups-bucket", "worker-feed", "worker-inventory", "worker-inventory-bucket"]),
        `unexpected worker grants: ${JSON.stringify([...members.keys()])}`);
    const grant = (name: string) => {
        const member = members.get(name)!;
        return {
            bucket: member.inputs.bucket,
            role: member.inputs.role,
            expression: (member.inputs.condition as { expression: string } | undefined)?.expression,
        };
    };

    const bucket = "example-project-nagare-pulumi-state";
    const inventoryRoot = `projects/_/buckets/${bucket}/objects/nagare/intranet/inventory/`;
    const feedRoot = `projects/_/buckets/${bucket}/objects/nagare/intranet/lifecycle/v1/`;
    const inventoryCondition = `resource.name == "projects/_/buckets/${bucket}" || resource.name.startsWith("${inventoryRoot}")`;
    const feedCondition = `resource.name.startsWith("${feedRoot}")`;
    assert(inventoryCondition === lifecycleInventoryReadCondition(bucket, "nagare/intranet/inventory"), "the inventory condition is not the shared expression");
    assert(feedCondition === lifecycleFeedWriteCondition(bucket, "nagare/intranet/inventory"), "the feed condition is not the shared expression");

    const expected = {
        "worker-inventory": { bucket, role: "roles/storage.objectViewer", expression: inventoryCondition },
        "worker-inventory-bucket": { bucket, role: "roles/storage.bucketViewer", expression: inventoryCondition },
        "worker-feed": { bucket, role: "roles/storage.objectUser", expression: feedCondition },
        "worker-backups": { bucket: "example-project-nagare-backups", role: "roles/storage.objectViewer", expression: undefined },
        "worker-backups-bucket": { bucket: "example-project-nagare-backups", role: "roles/storage.bucketViewer", expression: undefined },
    };
    for (const [name, want] of Object.entries(expected)) {
        assert(JSON.stringify(grant(name)) === JSON.stringify(want), `${name} is ${JSON.stringify(grant(name))}, not ${JSON.stringify(want)}`);
    }
    assert(lifecycleWorkerRoles.feedWriter === "roles/storage.objectUser", "the feed role changed");

    // The inventory and the backups are read-only, and the only role that can
    // write is bound to the lifecycle prefix alone: no bucket, no inventory.
    for (const name of ["worker-inventory", "worker-inventory-bucket", "worker-backups", "worker-backups-bucket"]) {
        assert(readOnlyRoles.has(String(grant(name).role)), `${name} binds a role that can write`);
    }
    for (const [name] of members) {
        const { role, expression } = grant(name);
        if (readOnlyRoles.has(String(role))) continue;
        assert(name === "worker-feed", `${name} binds the writable role ${String(role)}`);
        assert(expression === feedCondition, `the writable role is not restricted to the lifecycle prefix: ${expression}`);
        assert(!expression!.includes(inventoryRoot) && !expression!.includes(`"projects/_/buckets/${bucket}"`), "the feed write reaches the inventory or the bucket");
    }

    // The feed's location, as Nagare.Events.Target derives it.
    assert(lifecyclePrefix("nagare/intranet/inventory") === "nagare/intranet/lifecycle/v1", "the feed prefix differs from the inventory's sibling");
    assert(lifecyclePrefix("nagare/intranet/inventory/") === "nagare/intranet/lifecycle/v1", "a trailing slash changes the feed prefix");
    assert(lifecyclePrefix("nagare/intranet/store") === "nagare/intranet/store-lifecycle/v1", "a non-inventory prefix does not get the -lifecycle/v1 suffix");
    assert(lifecyclePrefix("inventory") === "lifecycle/v1", "a bare inventory prefix does not map to the worker's feed at the bucket root");
    process.stdout.write("lifecycle worker resources: OK\n");
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

main().catch((error) => {
    process.stderr.write(`${String(error)}\n`);
    process.exit(1);
});
