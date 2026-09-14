import {
    activatesCertificateMap,
    parseCdnCertificateMode,
    preparesCertificateMap,
    requireActiveCertificateState,
} from "../src/cdnCertificateMode";

const cases = [
    [undefined, "legacy", false, false],
    ["legacy", "legacy", false, false],
    ["prepare", "prepare", true, false],
    ["certificate-map", "certificate-map", true, true],
] as const;

for (const [input, expected, prepares, activates] of cases) {
    const mode = parseCdnCertificateMode(input);
    if (mode !== expected) {
        throw new Error(`${String(input)} parsed as ${mode}, expected ${expected}`);
    }
    if (preparesCertificateMap(mode) !== prepares || activatesCertificateMap(mode) !== activates) {
        throw new Error(`unexpected topology flags for ${mode}`);
    }
}

let rejected = false;
try {
    parseCdnCertificateMode("automatic");
} catch (error) {
    rejected = error instanceof Error && error.message.includes("legacy, prepare, or certificate-map");
}
if (!rejected) {
    throw new Error("invalid cdnCertificateMode did not fail closed");
}

requireActiveCertificateState("ACTIVE");
let prematureActivationRejected = false;
try {
    requireActiveCertificateState("PROVISIONING");
} catch (error) {
    prematureActivationRejected = error instanceof Error && error.message.includes("not ACTIVE");
}
if (!prematureActivationRejected) {
    throw new Error("non-ACTIVE Certificate Manager state was accepted");
}

console.log("ok");
