-- | Bootstrap / CloudflareZone. Executable-private CLI boundary.
--
-- A tunnel context's zone resources are their own reviewed stage, after the cluster exists and before
-- the platform, because the connector in the platform stage needs the token of the tunnel made here.
module Nagare.Cli.Bootstrap.CloudflareZone (buildCloudflareZoneStageCandidate) where

import Data.Generics.Labels ()
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map qualified as Map
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Cli.Runtime.Posture (ActivePosture)
import Nagare.Context.Posture (ZoneRecords (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Components.CloudflareZone
import Nagare.Ops.Pulumi (stackOutput)
import Nagare.Platform.Workspace (PlatformWorkspace)
import Nagare.Resource.Inventory qualified as ResourceInventory
import Nagare.Resource.Types qualified as Resource
import Nagare.Target
  ( ActiveTarget
  , IngressMode (IngressCloudflareTunnel)
  , contextNameText
  )
import System.Environment (lookupEnv)

buildCloudflareZoneStageCandidate ::
  ActivePosture ->
  ActiveTarget ->
  PlatformWorkspace ->
  ResourceInventory.ScopeSnapshot ->
  IO (Maybe ResourceInventory.CompositionCandidate)
buildCloudflareZoneStageCandidate current active workspace snapshot =
  case current ^. #posture . #zoneRecords of
    Nothing -> pure Nothing
    -- EP-243: while a move mirrors Cloud DNS, the records point at the VM's address, DNS-only.
    Just MirrorRecords -> do
      address <-
        stackOutput (workspace ^. #pulumiDir) "publicIp"
          >>= maybe (dieT "a context move mirrors Cloud DNS to the VM, but the stack has no publicIp output") pure
      zoneStage active (current ^. #zoneBase) snapshot (Just address)
    Just TunnelRecords -> zoneStage active (current ^. #zoneBase) snapshot Nothing

zoneStage :: ActiveTarget -> Text -> ResourceInventory.ScopeSnapshot -> Maybe Text -> IO (Maybe ResourceInventory.CompositionCandidate)
zoneStage active base snapshot mirror = do
  rawZone <-
    lookupEnv "CF_ZONE_ID"
      >>= maybe (dieT "a tunnel context requires CF_ZONE_ID, CF_ACCOUNT_ID and CF_API_TOKEN in the operator's environment") pure
  zone <- either dieT pure (Resource.mkName (T.pack rawZone))
  scope <-
    either
      (dieT . T.pack . show)
      pure
      ( compileCloudflareZone
          CloudflareZoneInput
            { zone = zone
            , baseDomain = base
            , context = contextNameText (active ^. #contextName)
            , mirrorAddress = mirror
            }
      )
  case Map.lookup cloudflareZoneOwner (ResourceInventory.snapshotScopes snapshot) of
    Just (_, accepted) | accepted == scope -> pure Nothing
    _ ->
      Just
        <$> either
          (dieT . T.pack . show)
          pure
          (ResourceInventory.composeInventory snapshot (ResourceInventory.ReplaceScope scope :| []))
