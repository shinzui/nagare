-- | Fixed allowlisted host-unit recovery transport. No operator shell input.
module Nagare.Inventory.BootstrapRegistryTransport
  ( runRegistryUnitTransport
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (eitherDecodeStrict')
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapters.Host
import Nagare.Inventory.BootstrapRegistryRecovery
import Nagare.Resource.Types
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

runRegistryUnitTransport ::
  FilePath ->
  [(String, String)] ->
  Text ->
  Text ->
  HostActivationPlan ->
  PhysicalIdentity ->
  Maybe RegistryUnitSnapshot ->
  IO (Either Text RegistryUnitSnapshot)
runRegistryUnitTransport helper additions instanceName registryHost plan deployment saved = do
  let vm = last (T.splitOn "/" (physicalIdentityText (hostPlanInstance plan)))
      values =
        [vm, hostPlanNewClosure plan, physicalIdentityText deployment, registryHost]
          <> maybe
            []
            ( \value ->
                [ T.pack (show (registryUnitStart value))
                , registryK3sInvocation value
                , registryNodeUid value
                , registryBootId value
                ]
            )
            saved
      allowed c = isAsciiLower c || isAsciiUpper c || isDigit c || c `elem` ("._/:-" :: String)
  if any (\value -> T.null value || T.any (not . allowed) value) values
    then pure (Left "registry transport identity contains unsupported characters")
    else do
      inherited <- getEnvironment
      let settings = ("NAGARE_INVENTORY_ADAPTER_CHILD", "bootstrap-registry") : additions
          names = map fst settings
          environment = settings <> filter ((`notElem` names) . fst) inherited
          arguments =
            [ if isJust saved then "recover" else "inspect"
            , vm
            , hostPlanNewClosure plan
            , physicalIdentityText deployment
            , registryHost
            ]
              <> maybe
                ["0", "none", "none", "none"]
                ( \value ->
                    [ T.pack (show (registryUnitStart value))
                    , registryK3sInvocation value
                    , registryNodeUid value
                    , registryBootId value
                    ]
                )
                saved
          remote =
            "sudo /run/current-system/sw/bin/bash -s -- "
              <> T.unwords (map (\value -> "'" <> value <> "'") arguments)
          command =
            (proc "bash" [helper, "ssh", T.unpack instanceName, "--", T.unpack remote])
              { env = Just environment
              }
      result <-
        timeout
          (180 * 1000000)
          (try (readCreateProcessWithExitCode command registryRemoteScript))
      pure $ case result of
        Nothing -> Left "registry recovery exceeded its 180-second transport budget; inspect saved intent"
        Just (Left (err :: IOException)) -> Left ("registry recovery transport unavailable: " <> T.pack (show err))
        Just (Right (ExitFailure code, _, errors)) ->
          let safe =
                filter
                  ("bootstrap registry recovery precondition failed: " `T.isPrefixOf`)
                  (T.lines (T.pack errors))
           in Left
                ( "registry recovery transport refused or became uncertain (exit "
                    <> T.pack (show code)
                    <> "); inspect saved intent"
                    <> maybe "" ("; " <>) (case safe of [] -> Nothing; line : _ -> Just line)
                )
        Just (Right (ExitSuccess, output, _)) ->
          first
            T.pack
            (eitherDecodeStrict' (TE.encodeUtf8 (T.strip (T.pack output))))

registryRemoteScript :: String
registryRemoteScript =
  unlines
    [ "set -euo pipefail"
    , "action=\"$1\"; expected_vm=\"$2\"; closure=\"$3\"; deployment_uid=\"$4\""
    , "registry_host=\"$5\"; saved_start=\"$6\"; saved_invocation=\"$7\"; saved_node=\"$8\"; saved_boot=\"$9\""
    , "export PATH=/run/current-system/sw/bin:/usr/bin:/bin"
    , "fail() { echo \"bootstrap registry recovery precondition failed: $1\" >&2; exit 2; }"
    , "# Lock before host observation: an earlier transport may still be finishing."
    , "if [ \"$action\" = recover ]; then"
    , "  exec 9>/run/lock/nagare-registry-recovery.lock"
    , "  flock -n 9 || fail concurrent-host-recovery"
    , "elif [ \"$action\" = inspect ]; then"
    , "  if [ -e /run/lock/nagare-registry-recovery.lock ]; then"
    , "    exec 9</run/lock/nagare-registry-recovery.lock"
    , "    flock -sn 9 || fail pending-host-recovery"
    , "  fi"
    , "else fail unsupported-action; fi"
    , "for assignment in $(systemctl show nagare-registries-refresh.service --property=Environment --value); do"
    , "  case \"$assignment\" in PATH=*) unit_path=\"${assignment#PATH=}\" ;; esac"
    , "done"
    , "[ -n \"${unit_path:-}\" ] || fail unit-environment"
    , "case \"$unit_path\" in *[!A-Za-z0-9._/:-]*) fail unit-path ;; esac"
    , "export PATH=\"$PATH:$unit_path\""
    , "guard_host() {"
    , "  [ \"$(curl -fsS --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/id)\" = \"$expected_vm\" ] || fail vm-identity"
    , "  [ \"$(readlink -f /run/current-system)\" = \"$closure\" ] || fail running-closure"
    , "  [ \"$(readlink -f /nix/var/nix/profiles/system)\" = \"$closure\" ] || fail boot-closure"
    , "  [ \"$(systemctl is-active nagare-switch-rollback.timer 2>/dev/null || true)\" != active ] || fail armed-rollback"
    , "}"
    , "snapshot() {"
    , "  guard_host"
    , "  systemctl is-active --quiet k3s.service || fail inactive-k3s"
    , "  [ \"$(systemctl show nagare-registries-refresh.service --property=ActiveState --value)\" = inactive ] || fail pending-refresh-unit"
    , "  [ \"$(systemctl show nagare-registries-refresh.service --property=ExecMainStatus --value)\" = 0 ] || fail refresh-unit-status"
    , "  refresh_job=\"$(systemctl show nagare-registries-refresh.service --property=Job --value)\""
    , "  k3s_job=\"$(systemctl show k3s.service --property=Job --value)\""
    , "  [ -z \"$refresh_job\" ] || fail pending-refresh-job"
    , "  [ -z \"$k3s_job\" ] || fail pending-k3s-job"
    , "  start=\"$(systemctl show nagare-registries-refresh.service --property=ExecMainStartTimestampMonotonic --value)\""
    , "  invocation=\"$(systemctl show k3s.service --property=InvocationID --value)\""
    , "  boot=\"$(cat /proc/sys/kernel/random/boot_id)\""
    , "  node=\"$(k3s kubectl get nodes -o json --request-timeout=10s | jq -er '.items | select(length == 1) | .[0].metadata.uid')\""
    , "  deployment=\"$(k3s kubectl get deployment net-certmanager-controller -n knative-serving -o json --request-timeout=10s)\""
    , "  actual_uid=\"$(printf '%s' \"$deployment\" | jq -er '.metadata.uid')\""
    , "  [ \"$actual_uid\" = \"$deployment_uid\" ] || fail deployment-identity"
    , "  ready=\"$(printf '%s' \"$deployment\" | jq -r '(.status.observedGeneration // 0) >= .metadata.generation and (.status.readyReplicas // 0) >= (.spec.replicas // 1) and (.status.updatedReplicas // 0) >= (.spec.replicas // 1) and any(.status.conditions[]?; .type == \"Available\" and .status == \"True\")')\""
    , "  unset deployment"
    , "  replicas=\"$(k3s kubectl get replicasets -n knative-serving -o json --request-timeout=10s | jq -c --arg uid \"$deployment_uid\" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.uid]')\""
    , "  pull=\"$(k3s kubectl get pods -n knative-serving -o json --request-timeout=10s | jq -r --argjson replicas \"$replicas\" 'any(.items[]; any(.metadata.ownerReferences[]?; .uid as $id | $replicas | index($id) != null) and any(.status.containerStatuses[]?; .state.waiting.reason == \"ImagePullBackOff\" or .state.waiting.reason == \"ErrImagePull\"))')\""
    , "  fresh=false"
    , "  [ \"$(stat -c '%a:%u' /etc/rancher/k3s/registries.yaml)\" = 600:0 ] || fail credential-file-permissions"
    , "  metadata=\"$(curl -fsS --max-time 10 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token)\""
    , "  token=\"$(printf '%s' \"$metadata\" | jq -er '.access_token | select(type == \"string\" and length > 0)')\""
    , "  lifetime=\"$(printf '%s' \"$metadata\" | jq -er '.expires_in | select(type == \"number\" and . > 0 and . <= 86400)')\" || fail invalid-metadata-token-lifetime"
    , "  # Compare in the root-only process; credential bytes never leave the host."
    , "  if [ \"$lifetime\" -ge 300 ] && REGISTRY_RECOVERY_TOKEN=\"$token\" awk -v host=\"$registry_host\" '"
    , "    index($0, \"\\\"\"host\"\\\"\") { selected=1 }"
    , "    selected && $1 == \"password:\" { sub(/^[[:space:]]*password:[[:space:]]*\"/,\"\"); sub(/\"[[:space:]]*$/,\"\"); if ($0 == ENVIRON[\"REGISTRY_RECOVERY_TOKEN\"]) found=1 }"
    , "    END { exit !found }' /etc/rancher/k3s/registries.yaml; then fresh=true; fi"
    , "  unset metadata token"
    , "}"
    , "snapshot"
    , "if [ \"$action\" = recover ]; then"
    , "  [ \"$node\" = \"$saved_node\" ] || fail node-changed"
    , "  if [ \"$ready\" = true ]; then"
    , "    : # Quiescent units and the original ready workload need no further effect."
    , "  else"
    , "    [ \"$boot\" = \"$saved_boot\" ] || fail boot-changed"
    , "    if [ \"$invocation\" != \"$saved_invocation\" ]; then"
    , "      [ \"$start\" != \"$saved_start\" ] || fail unproved-k3s-change"
    , "      # Completed phases remain proved after their token later expires."
    , "    else"
    , "      [ \"$pull\" = true ] || fail absent-image-pull-failure"
    , "      if [ \"$start\" = \"$saved_start\" ] || [ \"$fresh\" != true ]; then"
    , "        guard_host"
    , "        [ \"$lifetime\" -ge 900 ] || fail short-lived-metadata-token"
    , "        previous_start=\"$start\""
    , "        systemctl start nagare-registries-refresh.service"
    , "        snapshot"
    , "        [ \"$start\" != \"$previous_start\" ] && [ \"$fresh\" = true ] || fail unproved-registry-refresh"
    , "        [ \"$invocation\" = \"$saved_invocation\" ] || fail concurrent-k3s-change"
    , "      fi"
    , "      guard_host"
    , "      [ \"$lifetime\" -ge 900 ] || fail short-lived-metadata-token"
    , "      systemctl restart k3s.service"
    , "      deadline=$((SECONDS + 90))"
    , "      until k3s kubectl get --raw=/readyz --request-timeout=5s >/dev/null 2>&1; do"
    , "        [ \"$SECONDS\" -lt \"$deadline\" ] || fail k3s-readiness-budget"
    , "        sleep 2"
    , "      done"
    , "      snapshot"
    , "      [ \"$start\" != \"$saved_start\" ] && [ \"$invocation\" != \"$saved_invocation\" ] && [ \"$fresh\" = true ] || fail unproved-completion"
    , "      [ \"$node\" = \"$saved_node\" ] && [ \"$boot\" = \"$saved_boot\" ] || fail node-or-boot-changed"
    , "    fi"
    , "  fi"
    , "fi"
    , "jq -cn --argjson start \"$start\" --arg invocation \"$invocation\" --arg node \"$node\" --argjson fresh \"$fresh\" --argjson pull \"$pull\" --arg boot \"$boot\" --argjson ready \"$ready\" '{registryUnitStart:$start,registryK3sInvocation:$invocation,registryNodeUid:$node,registryTokenFresh:$fresh,registryPullFailure:$pull,registryBootId:$boot,registryDeploymentReady:$ready}'"
    ]
