{-# LANGUAGE OverloadedStrings #-}

-- | The content-app example's signing key set (MasterPlan 39, EP-286).
--
-- @view-grants@ is an Ed25519 key set the platform generates and rotates
-- every day, keeping a replaced key published for two hours. The web
-- Service @content-app@ signs with it and the Worker @content-gateway@
-- verifies with it; both read the files under
-- @/var/run/nagare/keysets/view-grants/@, which change in place.
--
-- Review it with:
--   nagarectl keyset plan --file cluster/examples/content-app/nagare/KeySets.hs --save-plan DIR
module Main (main) where

import Data.Text (Text)
import Data.Text qualified as Text
import Nagare.Dsl.Config (emitKeySets)
import Nagare.Dsl.KeySet (KeySet (..), mkKeySetName, mkMinutes, mkRotationPolicy)
import Nagare.Dsl.Types (mkNamespace)

viewGrants :: Either Text KeySet
viewGrants = do
  name <- mkKeySetName "view-grants"
  ns <- mkNamespace "personal"
  day <- mkMinutes (24 * 60)
  twoHours <- mkMinutes 120
  rotation <- mkRotationPolicy day twoHours
  pure KeySet {name = name, logicalKey = Nothing, namespace = ns, rotation = rotation}

main :: IO ()
main = either (ioError . userError . Text.unpack) (emitKeySets . pure) viewGrants
