import { DomainTopology, resolveDomainTopology } from "../src/domainTopology";

function assertTopology(
    label: string,
    actual: DomainTopology<string>,
    expected: DomainTopology<string>,
): void {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

const vm = "203.0.113.10";
const cdn = "198.51.100.20";

for (const enableCdn of [false, true]) {
    for (const cdnExists of [false, true]) {
        const label = `enableCdn=${enableCdn}, cdnExists=${cdnExists}`;
        assertTopology(
            label,
            resolveDomainTopology({ enableCdn, cdnExists, vmPublicIp: vm, cdnGlobalIp: cdn }),
            {
                wildcardIp: vm,
                apexIp: enableCdn && cdnExists ? cdn : vm,
            },
        );
    }
}

let missingCdnIpRejected = false;
try {
    resolveDomainTopology({ enableCdn: true, cdnExists: true, vmPublicIp: vm });
} catch (error) {
    missingCdnIpRejected = error instanceof Error && error.message.includes("global IP");
}
if (!missingCdnIpRejected) {
    throw new Error("a constructed CDN without a global IP was not rejected");
}

console.log("ok");
