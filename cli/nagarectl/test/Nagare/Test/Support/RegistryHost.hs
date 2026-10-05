-- | The host transport fixture: shell functions that stand in for the host
-- primitives the production registry transport's stdin script calls.
module Nagare.Test.Support.RegistryHost
  ( registryHostFixture
  )
where

import Nagare.Dsl.Prelude

-- Execute the production transport's actual stdin script against host responses.
-- Host primitives are intercepted; no credential file or provider is accessed.
registryHostFixture :: String
registryHostFixture =
  unlines
    [ "systemctl() {"
    , "  case \"$*\" in"
    , "    *nagare-switch-rollback.timer*) printf 'inactive\\n' ;;"
    , "    *--property=Environment*) printf 'PATH=/usr/bin\\n' ;;"
    , "    *--property=ActiveState*) printf 'inactive\\n' ;;"
    , "    *--property=ExecMainStatus*) printf '0\\n' ;;"
    , "    *--property=Job*) [ \"$NAGARE_TEST_JOB\" != lookup-failure ] || return 31; printf '%s\\n' \"$NAGARE_TEST_JOB\" ;;"
    , "    *--property=ExecMainStartTimestampMonotonic*) printf '10\\n' ;;"
    , "    *--property=InvocationID*) printf 'original\\n' ;;"
    , "    'is-active --quiet k3s.service') return 0 ;;"
    , "    *) return 32 ;;"
    , "  esac"
    , "}"
    , "curl() { case \"$*\" in */instance/id) printf '123\\n' ;; */default/token) printf '%s\\n' '{\"access_token\":\"fixture-token\",\"expires_in\":1200}' ;; *) return 33 ;; esac; }"
    , "readlink() { printf '/nix/store/accepted-test-closure\\n'; }"
    , "stat() { printf '600:0\\n'; }"
    , "cat() { [ \"$1\" = /proc/sys/kernel/random/boot_id ] || return 34; printf 'boot\\n'; }"
    , "awk() { return 1; }"
    , "flock() { return 0; }"
    , "jq() { \"$NAGARE_TEST_JQ\" \"$@\"; }"
    , "k3s() {"
    , "  case \"$*\" in"
    , "    'kubectl get nodes '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"uid\":\"node\"}}]}' ;;"
    , "    'kubectl get deployment '*) printf '%s\\n' '{\"metadata\":{\"uid\":\"deployment-uid\",\"generation\":1},\"spec\":{\"replicas\":1},\"status\":{\"observedGeneration\":1,\"readyReplicas\":0,\"updatedReplicas\":0,\"conditions\":[{\"type\":\"Available\",\"status\":\"False\"}]}}' ;;"
    , "    'kubectl get replicasets '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"uid\":\"replica-uid\",\"ownerReferences\":[{\"uid\":\"deployment-uid\"}]}}]}' ;;"
    , "    'kubectl get pods '*) printf '%s\\n' '{\"items\":[{\"metadata\":{\"ownerReferences\":[{\"uid\":\"replica-uid\"}]},\"status\":{\"containerStatuses\":[{\"state\":{\"waiting\":{\"reason\":\"ImagePullBackOff\"}}}]}}]}' ;;"
    , "    *) return 35 ;;"
    , "  esac"
    , "}"
    ]
