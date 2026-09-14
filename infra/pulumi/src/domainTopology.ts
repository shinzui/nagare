export interface DomainTopologyInputs<T> {
    enableCdn: boolean;
    cdnExists: boolean;
    vmPublicIp: T;
    cdnGlobalIp?: T;
}

export interface DomainTopology<T> {
    wildcardIp: T;
    apexIp: T;
}

/**
 * Select the two stable DNS targets for the Nagare application domain.
 *
 * Wildcard application names always enter through the VM. The exact apex may
 * enter through the standing CDN, but only when it was both requested and
 * actually constructed. Keeping this policy independent of Pulumi makes every
 * enablement/component-existence combination directly testable.
 */
export function resolveDomainTopology<T>(inputs: DomainTopologyInputs<T>): DomainTopology<T> {
    if (inputs.enableCdn && inputs.cdnExists) {
        if (inputs.cdnGlobalIp === undefined) {
            throw new Error("a constructed CDN must provide its global IP");
        }
        return {
            wildcardIp: inputs.vmPublicIp,
            apexIp: inputs.cdnGlobalIp,
        };
    }

    return {
        wildcardIp: inputs.vmPublicIp,
        apexIp: inputs.vmPublicIp,
    };
}
