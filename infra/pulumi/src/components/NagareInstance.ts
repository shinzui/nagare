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
    /** EP-99: GCP-level deletion protection. While true the Compute API refuses
     *  to delete this instance at all — `gcloud compute instances delete` fails
     *  and so does any Pulumi plan that would replace it. Set the Pulumi config
     *  `vmDeletionProtection` to false for a deliberate rebuild. */
    deletionProtection: pulumi.Input<boolean>;
    /** EP-99: boot disk size in GB (was hardcoded 100). */
    bootDiskSizeGb: number;
    /** EP-99: boot disk type (was implicit, i.e. the provider default
     *  pd-standard). Changing this against a live VM forces a REPLACEMENT —
     *  GCE cannot convert a boot disk's type in place. */
    bootDiskType: string;
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
            // EP-99: the Compute API refuses to delete a protected instance, so
            // an accidental `pulumi destroy` or `gcloud compute instances delete`
            // cannot take the platform down. Config-driven (`vmDeletionProtection`,
            // default true) because the intended rebuild path replaces the VM;
            // see the comment on that config read in infra/pulumi/index.ts.
            deletionProtection: args.deletionProtection,
            // Boot disk holds NixOS /nix/store AND the containerd image store, so
            // it must be sized for the cluster's images, not just the OS. The image's
            // default (~6 GB) tripped DiskPressure during the EP-5 observability
            // install (see MasterPlan Surprises, 2026-06-02). NixOS auto-grows the
            // root partition (google-compute-image.nix `growPartition`) to fill this.
            bootDisk: {
                initializeParams: {
                    image: args.imageSelfLink,
                    size: args.bootDiskSizeGb,
                    type: args.bootDiskType,
                },
            },
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
            // No `enable-oslogin` metadata (EP-99). It used to be set to "TRUE"
            // here, but it was inert and misleading: the image force-disables OS
            // Login (nixos/hosts/nagare-01/security.nix,
            // `security.googleOsLogin.enable = lib.mkForce false`). SSH really
            // works as the `deploy` user's declarative authorized_keys
            // (nixos/hosts/nagare-01/users.nix) reached over the IAP tunnel
            // (scripts/iap-ssh.sh).
            //
            // The data disk must survive the VM. Leave it out of the
            // instance lifecycle: it is its own gcp.compute.Disk resource.
        }, { parent: this });

        this.registerOutputs({});
    }
}
