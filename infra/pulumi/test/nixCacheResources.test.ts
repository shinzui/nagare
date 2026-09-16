import * as pulumi from "@pulumi/pulumi";
import { NagareNixCache } from "../src/components/NagareNixCache";

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
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? args.name };
            if (args.type === "gcp:storage/hmacKey:HmacKey") {
                state.accessId = "GOOG1EXAMPLE";
                state.secret = "test-secret-never-printed";
            }
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "nix-cache", true);

    const disabled = new NagareNixCache("disabled-cache", {
        enabled: false,
        gcpProject: "example-project",
        region: "us-west1",
        bucketName: "example-project-disabled-cache",
        serviceAccountEmail: "node@example-project.iam.gserviceaccount.com",
    });
    const enabled = new NagareNixCache("enabled-cache", {
        enabled: true,
        gcpProject: "example-project",
        region: "us-west1",
        bucketName: "example-project-nagare-nix-cache",
        serviceAccountEmail: "node@example-project.iam.gserviceaccount.com",
    });

    await (enabled.hmacAccessId as unknown as { promise(): Promise<string> }).promise();
    const secret = await pulumi.isSecret(enabled.hmacSecret);
    const disabledSecret = await pulumi.isSecret(disabled.hmacSecret);
    await pulumi.runtime.disconnect();

    const gcpResources = resources.filter((resource) => resource.type.startsWith("gcp:"));
    if (gcpResources.some((resource) => resource.name.startsWith("disabled-cache"))) {
        throw new Error(`disabled cache created GCP resources: ${JSON.stringify(gcpResources)}`);
    }
    if (gcpResources.length !== 3) {
        throw new Error(`enabled cache should create bucket, IAM member, and HMAC key; got ${gcpResources.length}`);
    }
    const bucket = gcpResources.find((resource) => resource.type === "gcp:storage/bucket:Bucket");
    if (bucket?.inputs.forceDestroy !== false || bucket.inputs.uniformBucketLevelAccess !== true || bucket.inputs.publicAccessPrevention !== "enforced") {
        throw new Error(`cache bucket safety settings are incomplete: ${JSON.stringify(bucket)}`);
    }
    if ("versioning" in (bucket?.inputs ?? {})) {
        throw new Error("cache bucket must not retain noncurrent chunk generations");
    }
    const member = gcpResources.find((resource) => resource.type === "gcp:storage/bucketIAMMember:BucketIAMMember");
    if (member?.inputs.role !== "roles/storage.objectAdmin") {
        throw new Error(`unexpected cache IAM role: ${JSON.stringify(member)}`);
    }
    if (!secret || !disabledSecret) {
        throw new Error("HMAC secret outputs must remain Pulumi secrets in both branches");
    }

    console.log("ok");
}

main().catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
});
