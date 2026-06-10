import * as pulumi from "@pulumi/pulumi";
import * as gcp from "@pulumi/gcp";

export interface NagareInstanceArgs {
    zone: string;
    machineType: string;
    /** Self-link of the registered NixOS GCE image (Pulumi config key
     *  `nagareImageSelfLink`, written by EP-3's scripts/upload-images.sh). */
    imageSelfLink: string;
    subnetId: pulumi.Input<string>;
    /** The reserved static external IP address (string form). */
    publicIp: pulumi.Input<string>;
    /** The persistent data disk to attach (its self-link/id). */
    dataDiskId: pulumi.Input<string>;
    serviceAccountEmail: pulumi.Input<string>;
}

export class NagareInstance extends pulumi.ComponentResource {
    public readonly instance: gcp.compute.Instance;

    constructor(name: string, args: NagareInstanceArgs, opts?: pulumi.ComponentResourceOptions) {
        super("nagare:compute:NagareInstance", name, {}, opts);

        this.instance = new gcp.compute.Instance(name, {
            name,                       // GCE instance name == resource name == "nagare-01"
            zone: args.zone,
            machineType: args.machineType,
            // GCP cannot change machineType on a running VM. Without this,
            // bumping `machineType` (a vertical resize to a bigger machine)
            // fails on `pulumi up`. With it, Pulumi stops the VM, changes the
            // type, and restarts it — the boot disk, data disk, and static IP
            // all persist, so the only cost is a brief stop/start window. See
            // docs/user/resizing-the-vm.md.
            allowStoppingForUpdate: true,
            // Boot disk holds NixOS /nix/store AND the containerd image store, so
            // it must be sized for the cluster's images, not just the OS. The image's
            // default (~6 GB) tripped DiskPressure during the EP-5 observability
            // install (see MasterPlan Surprises, 2026-06-02). NixOS auto-grows the
            // root partition (google-compute-image.nix `growPartition`) to fill this.
            bootDisk: { initializeParams: { image: args.imageSelfLink, size: 100 } },
            attachedDisks: [{
                source: args.dataDiskId,
                deviceName: "nagare-data",   // stable device name EP-3 mounts at /var/lib/nagare
                mode: "READ_WRITE",
            }],
            networkInterfaces: [{
                subnetwork: args.subnetId,
                // Assign the reserved static external IP so the VM is
                // reachable at a fixed, DNS-able address.
                accessConfigs: [{ natIp: args.publicIp }],
            }],
            serviceAccount: {
                email: args.serviceAccountEmail,
                // cloud-platform is the modern catch-all scope; real
                // authorization comes from the IAM roles granted to this
                // service account in NagarePerimeter, not from scopes.
                scopes: ["cloud-platform"],
            },
            // OS Login lets IAM control SSH access via the IAP tunnel.
            metadata: { "enable-oslogin": "TRUE" },
            // The data disk must survive the VM. Leave it out of the
            // instance lifecycle: it is its own gcp.compute.Disk resource.
        }, { parent: this });

        this.registerOutputs({});
    }
}
