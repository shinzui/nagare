-- | EP-173 M2: an inventory object store whose puts and gets an adversary can
-- refuse, land without acknowledgement, or fail once. It wraps any 'ObjectOps'
-- (normally the in-memory fake), generalizing the F38 spec's faulting store.
module Nagare.Test.World.Store
  ( faultingObjectOps
  )
where

import Control.Exception (throwIO)
import Data.Aeson (Value (..), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (traverse_)
import Data.IORef
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps
import Nagare.Resource.Wire (canonicalValue)
import Nagare.Test.World.Adversary

faultingObjectOps :: IORef Adversary -> ObjectOps -> ObjectOps
faultingObjectOps adversary base =
  base
    { putObject = \condition name bytes -> do
        placement <- nextFaultAt adversary StorePutCall
        -- EP-182: every store fault but a lost claim changes the answer it
        -- fires at; a lost claim acts only on a head write it can steal.
        let acts = traverse_ (noteActed adversary) placement
        case snd <$> placement of
          Just PutRefused -> acts >> pure (PutUnknown "injected: store write refused before landing")
          Just PutLandedUnacknowledged -> do
            _ <- putObject base condition name bytes
            acts >> pure (PutUnknown "injected: store write acknowledgement lost")
          Just CrashBeforeStorePut -> acts >> throwIO Interrupted
          Just CrashAfterStorePut -> putObject base condition name bytes >> acts >> throwIO Interrupted
          Just ClaimLost -> do
            stolen <- stealClaim condition name
            when stolen acts
            putObject base condition name bytes
          _ -> putObject base condition name bytes
    , getObject = \name -> do
        placement <- nextFaultAt adversary StoreGetCall
        case snd <$> placement of
          Just GetFailedOnce -> traverse_ (noteActed adversary) placement >> pure (GetUnknown "injected: store read failed")
          _ -> getObject base name
    }
  where
    -- Another client's claim lands at the generation this write expects, so
    -- the write itself then conflicts and the executor finds it has lost.
    stealClaim condition (ObjectName name) = case condition of
      IfGenerationMatches generation | "head.json" `T.isSuffixOf` name -> do
        current <- getObject base (ObjectName name)
        case current of
          ObjectFound found bytes
            | found == generation
            , Right (Object root) <- eitherDecodeStrict' bytes
            , Just (Object claim) <- KM.lookup "executorClaim" root
            , Right stolen <- canonicalValue (Object (KM.insert "executorClaim" (Object (KM.insert "clientIdentity" (String "model-intruder") claim)) root)) ->
                True <$ putObject base condition (ObjectName name) stolen
          _ -> pure False
      _ -> pure False
