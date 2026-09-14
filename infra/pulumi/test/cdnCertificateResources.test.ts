import * as pulumi from "@pulumi/pulumi";
import { CdnCertificateMode } from "../src/cdnCertificateMode";
import { NagareCdn } from "../src/components/NagareCdn";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

async function resourcesFor(mode: CdnCertificateMode, certificateState = "ACTIVE"): Promise<RecordedResource[]> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            const state: Record<string, unknown> = { ...args.inputs, name: args.inputs.name ?? args.name };
            if (args.type === "gcp:compute/globalAddress:GlobalAddress") {
                state.address = "203.0.113.20";
            }
            if (args.type === "gcp:certificatemanager/dnsAuthorization:DnsAuthorization") {
                state.dnsResourceRecords = [{
                    name: "_acme-challenge.apps.example.test.",
                    type: "CNAME",
                    data: "authorization.example.net.",
                }];
            }
            if (args.type === "gcp:certificatemanager/certificate:Certificate") {
                state.managed = { ...(args.inputs.managed as object), state: certificateState };
            }
            return { id: `${args.name}-id`, state };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", `certificate-${mode}`, true);

    const cdn = new NagareCdn(`nagare-${mode}`, {
        gcpProject: "example-project",
        region: "us-west1",
        zone: "us-west1-a",
        baseDomain: "apps.example.test",
        instanceSelfLink: "instance-self-link",
        network: "network-id",
        publicIp: "203.0.113.10",
        dnsZone: "nagare-zone",
        certificateMode: mode,
    });
    await (cdn.cdnUrlMap as unknown as { promise(): Promise<string> }).promise();
    await pulumi.runtime.disconnect();
    return resources;
}

function one(resources: RecordedResource[], type: string): RecordedResource {
    const found = resources.filter((resource) => resource.type === type);
    if (found.length !== 1) {
        throw new Error(`expected one ${type}, got ${found.length}`);
    }
    return found[0];
}

async function main(): Promise<void> {
    const legacy = await resourcesFor("legacy");
    const legacyProxy = one(legacy, "gcp:compute/targetHttpsProxy:TargetHttpsProxy");
    if (!("sslCertificates" in legacyProxy.inputs) || "certificateMap" in legacyProxy.inputs) {
        throw new Error(`legacy proxy arguments are unsafe: ${JSON.stringify(legacyProxy.inputs)}`);
    }
    if (legacy.some((resource) => resource.type.startsWith("gcp:certificatemanager/"))) {
        throw new Error("legacy mode unexpectedly created Certificate Manager resources");
    }

    const prepare = await resourcesFor("prepare");
    const prepareProxy = one(prepare, "gcp:compute/targetHttpsProxy:TargetHttpsProxy");
    if (!("sslCertificates" in prepareProxy.inputs) || "certificateMap" in prepareProxy.inputs) {
        throw new Error(`prepare mode changed serving: ${JSON.stringify(prepareProxy.inputs)}`);
    }
    const certificate = one(prepare, "gcp:certificatemanager/certificate:Certificate");
    const managed = certificate.inputs.managed as { domains?: string[] };
    if (JSON.stringify(managed.domains) !== JSON.stringify(["apps.example.test", "*.apps.example.test"])) {
        throw new Error(`unexpected certificate SANs: ${JSON.stringify(certificate.inputs)}`);
    }
    const entries = prepare.filter(
        (resource) => resource.type === "gcp:certificatemanager/certificateMapEntry:CertificateMapEntry",
    );
    if (entries.length !== 2) {
        throw new Error(`expected exact and wildcard map entries, got ${entries.length}`);
    }
    one(prepare, "gcp:dns/recordSet:RecordSet");

    const active = await resourcesFor("certificate-map");
    const activeProxy = one(active, "gcp:compute/targetHttpsProxy:TargetHttpsProxy");
    if (!("certificateMap" in activeProxy.inputs) || "sslCertificates" in activeProxy.inputs) {
        throw new Error(`certificate-map proxy arguments are unsafe: ${JSON.stringify(activeProxy.inputs)}`);
    }

    console.log("ok");
}

main().catch((error: unknown) => {
    console.error(error);
    process.exitCode = 1;
});
