let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/package.dhall
        sha256:1501e5c3e55e78d2a58774e2f8aefda20e32b948fa7caf639473fce90929464b

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
      , Schema.Package::{
        , name = "nagare-access"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "cli/nagare-access"
        , description = Some
            "Shared forward-auth enforcer for protected Nagare sites. It will verify shomei sessions, check en authorization, and proxy authorized requests to cluster-local backends."
        }
      ]
    , docs =
      [ Schema.DocRef::{
        , key = "plan-registry"
        , kind = Schema.DocKind.Reference
        , audience = Schema.DocAudience.Internal
        , description = Some
            "Curated index for standalone ExecPlans, retired-plan successors, and cross-project plan lineage."
        , location = Schema.DocLocation.LocalFile "docs/plan-registry.md"
        }
      , Schema.DocRef::{
        , key = "masterplans"
        , kind = Schema.DocKind.Spec
        , audience = Schema.DocAudience.Internal
        , description = Some "Nagare MasterPlans and their authoritative child-plan registries."
        , location = Schema.DocLocation.LocalDir "docs/masterplans"
        }
      , Schema.DocRef::{
        , key = "execplans"
        , kind = Schema.DocKind.Spec
        , audience = Schema.DocAudience.Internal
        , description = Some "Nagare implementation ExecPlans."
        , location = Schema.DocLocation.LocalDir "docs/plans"
        }
      , Schema.DocRef::{
        , key = "user-manual"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Nagare operator manual, command reference, and feature documentation."
        , location = Schema.DocLocation.LocalDir "docs/user"
        }
      , Schema.DocRef::{
        , key = "guides"
        , kind = Schema.DocKind.Guide
        , audience = Schema.DocAudience.User
        , description = Some
            "Goal-oriented walkthroughs that combine Nagare features into complete operating patterns."
        , location = Schema.DocLocation.LocalDir "docs/guides"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What Nagare provides today, one concept per capability, with evidence"
        }
      , Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Nagare-owned improvement requests"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Commit-pinned records of Nagare artifacts having been reviewed"
        }
      , Schema.OkfBundle::{
        , name = "use-cases"
        , path = "docs/use-cases"
        , profile = Some "docs/use-cases/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "JTBD use cases Nagare owns, with the features their delivery depends on"
        }
      , Schema.OkfBundle::{
        , name = "user-documentation"
        , path = "docs/user"
        , profile = Some "mori/user-documentation-profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Nagare operator manual, command reference, and feature documentation"
        }
      , Schema.OkfBundle::{
        , name = "guides"
        , path = "docs/guides"
        , profile = Some "mori/user-documentation-profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Goal-oriented walkthroughs that combine Nagare features into complete operating patterns"
        }
      ]
    }
