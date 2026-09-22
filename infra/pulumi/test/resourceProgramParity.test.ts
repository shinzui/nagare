import { spawnSync } from "node:child_process";

type Registration = { pulumiType: string; pulumiName: string };

async function observeProgram(variant: string): Promise<void> {
    const observed: Registration[] = [];
    const config: Record<string, string> = {
        "gcp:project": "example-project",
        "gcp:region": "us-west1",
        "gcp:zone": "us-west1-a",
        "nagare:imageBucket": "example-images",
    };
    if (variant.includes("image") || variant.includes("cdn-")) config["nagare:nagareImageSelfLink"] = "projects/example-project/global/images/nagare-image";
    if (variant.includes("cache")) config["nagare:enableNixCache"] = "true";
    if (variant.includes("cdn-legacy")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "legacy";
    }
    if (variant.includes("cdn-manager")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "certificate-map";
    }
    if (variant.includes("cdn-prepare")) {
        config["nagare:enableCdn"] = "true";
        config["nagare:cdnCertificateMode"] = "prepare";
    }
    process.env.PULUMI_CONFIG = JSON.stringify(config);
    delete process.env.NAGARE_RESOURCE_DECLARATIONS;
    const pulumi = await import("@pulumi/pulumi");
    await pulumi.runtime.setMocks({
        call: (args) => args.inputs,
        newResource: (args) => {
            if (args.type.startsWith("gcp:") || args.type.startsWith("nagare:")) {
                observed.push({ pulumiType: args.type, pulumiName: args.name });
            }
            return {
                id: `${args.name}-id`,
                state: {
                    ...args.inputs,
                    id: `${args.name}-id`,
                    name: args.inputs.name ?? args.name,
                    selfLink: `https://example.invalid/${args.name}`,
                    email: `${args.name}@example-project.iam.gserviceaccount.com`,
                    accessId: `${args.name}-access-id`,
                    secret: `${args.name}-secret`,
                    managed: args.inputs.managed ? { ...args.inputs.managed, state: "ACTIVE" } : undefined,
                    managedZone: args.inputs.managedZone ?? "nagare-zone",
                    dnsResourceRecords: [{ name: "_acme.example.invalid.", type: "CNAME", data: "authorization.example.invalid." }],
                },
            };
        },
    }, "nagare", "dev", true);
    const program = await import("../index");
    void program;
    await pulumi.runtime.disconnect();
    observed.sort((left, right) => `${left.pulumiType}\0${left.pulumiName}`.localeCompare(`${right.pulumiType}\0${right.pulumiName}`));
    process.stdout.write(`${JSON.stringify(observed)}\n`);
}

function runVariant(variant: string): Registration[] {
    const result = spawnSync(process.execPath, [__filename, variant], { encoding: "utf8" });
    if (result.status !== 0) throw new Error(`resource program fixture ${variant} failed: ${result.stderr}${result.stdout}`);
    return JSON.parse(result.stdout.trim()) as Registration[];
}

function names(values: Registration[]): Set<string> {
    return new Set(values.map((value) => `${value.pulumiType}::${value.pulumiName}`));
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

async function main(): Promise<void> {
    const variant = process.argv[2];
    if (variant) {
        await observeProgram(variant);
        return;
    }
    const base = runVariant("base");
    const image = runVariant("image");
    const cache = runVariant("cache");
    const legacyCdn = runVariant("cdn-legacy");
    const prepareCdn = runVariant("cdn-prepare");
    const managerCdn = runVariant("cdn-manager");
    for (const [label, registrations] of Object.entries({ base, image, cache, legacyCdn, prepareCdn, managerCdn })) {
        assert(names(registrations).size === registrations.length, `${label} contains duplicate native registrations`);
    }
    assert(base.length === 31, `base cloud topology changed: expected 31 registrations, got ${base.length}`);
    assert(image.length === base.length + 2, "image-enabled topology must add the instance component and GCE instance");
    assert(cache.length === base.length + 3, "cache-enabled topology must add its bucket, IAM member, and HMAC key");
    assert(legacyCdn.length === base.length + 14, "legacy-CDN topology registration delta changed");
    assert(managerCdn.length === legacyCdn.length + 6, "Certificate Manager topology must retain the legacy certificate while adding six managed resources");
    assert(JSON.stringify(prepareCdn) === JSON.stringify(managerCdn), "Certificate preparation and activation must retain identical resource membership");
    assert(names(image).has("gcp:compute/instance:Instance::nagare-01"), "image topology omitted the GCE instance");
    assert(names(cache).has("gcp:storage/hmacKey:HmacKey::nagare-nix-cache-hmac"), "cache topology omitted its HMAC credential");
    assert(names(managerCdn).has("gcp:certificatemanager/certificateMap:CertificateMap::nagare-cdn-certificate-map"), "Certificate Manager topology omitted its map");
    console.log("ok");
}

void main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
