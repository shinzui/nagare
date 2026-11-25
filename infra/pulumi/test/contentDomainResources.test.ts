import * as pulumi from "@pulumi/pulumi";
import { NagareContentDomain, contentDomainZoneName, parseContentDomains } from "../src/components/NagareContentDomain";

interface RecordedResource {
    type: string;
    name: string;
    inputs: Record<string, unknown>;
}

function assert(condition: boolean, message: string): void {
    if (!condition) throw new Error(message);
}

function refuses(raw: string): boolean {
    try {
        parseContentDomains(raw);
        return false;
    } catch {
        return true;
    }
}

// EP-285: a content domain is its own zone with wildcard and apex records to the VM's
// address, and the VM account may write records in that zone only.
async function main(): Promise<void> {
    const resources: RecordedResource[] = [];
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            resources.push({ type: args.type, name: args.name, inputs: args.inputs });
            return { id: `${args.name}-id`, state: { ...args.inputs, name: args.inputs.name ?? args.name } };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "test", true);
    new NagareContentDomain("nagare-content-content-example-org", {
        gcpProject: "example-project",
        domain: "content.example.org",
        vmAddress: "203.0.113.10",
        serviceAccountEmail: "nagare-node@example-project.iam.gserviceaccount.com",
    });
    await new Promise((resolve) => setTimeout(resolve, 50));
    await pulumi.runtime.disconnect();

    const zone = resources.find((r) => r.type === "gcp:dns/managedZone:ManagedZone");
    assert(zone?.inputs.dnsName === "content.example.org.", "the zone does not serve the content domain");
    assert(zone?.inputs.name === "nagare-content-content-example-org", "the zone name is not the fixed one nagarectl describes");
    const records = resources.filter((r) => r.type === "gcp:dns/recordSet:RecordSet");
    assert(JSON.stringify(records.map((r) => r.inputs.name).sort()) === JSON.stringify(["*.content.example.org.", "content.example.org."]),
        "the content domain does not have exactly its wildcard and apex records");
    for (const record of records) {
        assert(JSON.stringify(record.inputs.rrdatas) === JSON.stringify(["203.0.113.10"]), `${String(record.inputs.name)} does not point at the VM`);
        assert(record.inputs.managedZone === "nagare-content-content-example-org", `${String(record.inputs.name)} is not in the content zone`);
    }
    const grants = resources.filter((r) => r.type.includes("IamMember") || r.type.includes("IAMMember"));
    assert(grants.length === 1, "a content domain grants more than the zone's DNS admin");
    assert(grants[0].type === "gcp:dns/dnsManagedZoneIamMember:DnsManagedZoneIamMember"
        && grants[0].inputs.managedZone === "nagare-content-content-example-org"
        && grants[0].inputs.role === "roles/dns.admin"
        && grants[0].inputs.member === "serviceAccount:nagare-node@example-project.iam.gserviceaccount.com",
        "the solver grant is not roles/dns.admin on the content zone for the VM account");

    assert(JSON.stringify(parseContentDomains(undefined)) === "[]" && JSON.stringify(parseContentDomains(" ")) === "[]", "an absent list is not empty");
    assert(JSON.stringify(parseContentDomains("a.example, b.example")) === JSON.stringify(["a.example", "b.example"]), "a list is not parsed in order");
    for (const raw of ["example", "*.example.org", "Example.org", "a.example,a.example", "a-b.example,a.b-example", `${"x".repeat(45)}.org`]) {
        assert(refuses(raw), `nagare:contentDomains accepted ${raw}`);
    }
    assert(contentDomainZoneName("content.example.org") === "nagare-content-content-example-org", "the zone name changed");
    console.log("ok");
}

void main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
