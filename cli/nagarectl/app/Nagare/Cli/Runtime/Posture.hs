-- | The active context's ingress posture (EP-243): its profile's ingress, and while a context move
-- is open, the move's steps in effect. Planning and apply both read it here, so a review and its
-- execution see the same posture.
module Nagare.Cli.Runtime.Posture
  ( ActivePosture (..)
  , activePosture
  , postureOf
  )
where

import Data.Foldable (forM_)
import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Cli.Runtime.Error (dieT)
import Nagare.Context.BaseFlip (baseEnvironmentRefusal)
import Nagare.Context.Posture
import Nagare.Dsl.Prelude
import Nagare.Inventory.Command (openTargetStoreReadOnly)
import Nagare.Inventory.Store (HeadManifest (..), readHead)
import Nagare.Inventory.Store.Manifest (MoveMarker (..))
import Nagare.Target (ActiveTarget, Mode (Local))
import System.Environment (lookupEnv)

data ActivePosture = ActivePosture
  { posture :: !IngressPosture
  , retainedDnsName :: !Text
  -- ^ The Cloud DNS name a closed perimeter keeps: the open move's, else the profile's.
  , zoneBase :: !Text
  -- ^ The base the Cloudflare zone and tunnel serve: the open move's target (EP-246 plans the new zone
  -- before its flip), else the profile's.
  }
  deriving stock (Eq, Show, Generic)

-- | A local context never moves, so it reads no head.
activePosture :: ActiveTarget -> IO ActivePosture
activePosture active
  | profile ^. #mode == Local = pure (ActivePosture (postureFor (profile ^. #ingress) Nothing) (profile ^. #retainedDnsName) (profile ^. #baseDomain))
  | otherwise = do
      store <- openTargetStoreReadOnly active >>= either (dieT . T.pack . show) pure
      marker <- readHead store >>= either (dieT . T.pack . show) (pure . (>>= headMove))
      -- EP-246 D2: a shell loaded before a base move's flip would plan for the wrong base.
      environment <- fmap T.pack <$> lookupEnv "NAGARE_BASE_DOMAIN"
      forM_ (marker >>= (`baseEnvironmentRefusal` environment)) dieT
      pure (postureOf active marker)
  where
    profile = active ^. #profile

-- | The posture from a head the caller already read.
postureOf :: ActiveTarget -> Maybe MoveMarker -> ActivePosture
postureOf active marker =
  ActivePosture
    { posture = postureFor (profile ^. #ingress) (moveProgress <$> marker)
    , retainedDnsName = maybe (profile ^. #retainedDnsName) moveRetainedDnsName marker
    , zoneBase = maybe (profile ^. #baseDomain) moveTargetBase marker
    }
  where
    profile = active ^. #profile
