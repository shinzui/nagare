export type CdnCertificateMode = "legacy" | "prepare" | "certificate-map";

/**
 * Parse the explicit edge-certificate migration state. An absent value keeps
 * existing stacks on the legacy Compute managed certificate. Invalid text is
 * an error: silently falling back could detach the serving certificate.
 */
export function parseCdnCertificateMode(value: string | undefined): CdnCertificateMode {
    if (value === undefined || value === "legacy") {
        return "legacy";
    }
    if (value === "prepare" || value === "certificate-map") {
        return value;
    }
    throw new Error(
        `invalid nagare:cdnCertificateMode ${JSON.stringify(value)}; expected legacy, prepare, or certificate-map`,
    );
}

export function preparesCertificateMap(mode: CdnCertificateMode): boolean {
    return mode !== "legacy";
}

export function activatesCertificateMap(mode: CdnCertificateMode): boolean {
    return mode === "certificate-map";
}

export function requireActiveCertificateState(state: string | undefined): void {
    if (state !== "ACTIVE") {
        throw new Error(`refusing certificate-map activation: certificate is ${state ?? "UNKNOWN"}, not ACTIVE`);
    }
}
