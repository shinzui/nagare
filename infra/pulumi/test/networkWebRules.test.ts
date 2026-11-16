import * as pulumi from "@pulumi/pulumi";
import { NagareNetwork } from "../src/components/NagareNetwork";

// EP-243: a move disables the web rules in place, so rollback can enable them again; with no move
// the rules carry no `disabled` input at all, so a direct stack previews unchanged.
async function firewallInputs(webRulesDisabled?: boolean): Promise<Map<string, Record<string, unknown>>> {
    const recorded = new Map<string, Record<string, unknown>>();
    await pulumi.runtime.setMocks({
        newResource: (args: pulumi.runtime.MockResourceArgs) => {
            if (args.type === "gcp:compute/firewall:Firewall") recorded.set(args.name, args.inputs);
            return { id: `${args.name}-id`, state: { ...args.inputs, name: args.inputs.name ?? args.name } };
        },
        call: (args: pulumi.runtime.MockCallArgs) => args.inputs,
    }, "nagare", "test", true);
    new NagareNetwork("nagare-network", { region: "us-west1", webRulesDisabled });
    await pulumi.runtime.disconnect();
    return recorded;
}

async function main(): Promise<void> {
    const webRules = ["nagare-network-fw-web", "nagare-network-fw-lb-health", "nagare-network-fw-tailscale"];
    const direct = await firewallInputs(undefined);
    for (const rule of [...webRules, "nagare-network-fw-iap-ssh"]) {
        const inputs = direct.get(rule);
        if (!inputs) throw new Error(`direct context lost ${rule}`);
        if ("disabled" in inputs) throw new Error(`direct ${rule} gained a disabled input`);
    }
    const moving = await firewallInputs(true);
    for (const rule of webRules) {
        if (moving.get(rule)?.disabled !== true) throw new Error(`a moving context's ${rule} is not disabled`);
    }
    if ("disabled" in (moving.get("nagare-network-fw-iap-ssh") ?? {})) throw new Error("a move disabled the IAP SSH rule");
    console.log("network web rules: OK");
}

main().catch((error) => {
    console.error(error);
    process.exit(1);
});
