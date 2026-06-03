let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "nagare"
      , namespace = "shinzui"
      , type = Schema.PackageType.Application
      , language = Schema.Language.Nix
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Nagare (流れ, \"flow\") — a cheap, single-node personal PaaS on one GCP Compute Engine VM. Pulumi owns cloud resources, NixOS owns the host, k3s owns the cluster, Knative owns app deployment, the VictoriaMetrics/Logs/Traces stack owns observability, and the nagarectl CLI owns the developer experience: one project = one Knative Service, deployed with `nagarectl deploy`."
      , domains = [ "Infrastructure", "PaaS", "Kubernetes" ]
      , owners = [ "shinzui" ]
      }
    , repos =
      [ Schema.Repo::{ name = "nagare", github = Some "shinzui/nagare" } ]
    , packages =
      [ Schema.Package::{
        , name = "infra-pulumi"
        , type = Schema.PackageType.Application
        , language = Schema.Language.TypeScript
        , path = Some "infra/pulumi"
        , description = Some
            "Pulumi (TypeScript) project provisioning the GCP Compute Engine VM, static IP, Cloud DNS, persistent disks, IAM, and GCS backup buckets."
        }
      , Schema.Package::{
        , name = "nixos-hosts"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Nix
        , path = Some "nixos"
        , description = Some
            "NixOS host configuration for nagare-01: users, SSH, firewall, disks, Tailscale, sops-nix, k3s (Traefik/servicelb disabled), and backup tooling. Recovery is `nixos-rebuild switch` on a disposable machine."
        }
      , Schema.Package::{
        , name = "cluster-bootstrap"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Other "YAML"
        , path = Some "cluster/bootstrap"
        , description = Some
            "Cluster bootstrap manifests: cert-manager, Knative Serving, Kourier/Envoy ingress, and config-domain wiring for wildcard DNS and TLS."
        }
      , Schema.Package::{
        , name = "cluster-observability"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Other "YAML"
        , path = Some "cluster/observability"
        , description = Some
            "Observability stack manifests: VictoriaMetrics, VictoriaLogs, VictoriaTraces, the OpenTelemetry Collector, and Grafana dashboards — a low-overhead replacement for Prometheus + Loki + Tempo on a single-node box."
        }
      , Schema.Package::{
        , name = "nagarectl"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "cli/nagarectl"
        , description = Some
            "The deploy CLI. `nagarectl deploy` loads a project's typed config-as-program (nagare/Config.hs, via nagare-dsl), builds and pushes the image, renders and applies a Knative Service, wires secrets and domains, waits for readiness, and prints the URL — hiding Kubernetes from the developer."
        }
      ]
    }
