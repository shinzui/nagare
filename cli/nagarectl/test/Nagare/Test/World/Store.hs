-- | EP-173 M2: an inventory object store whose puts and gets an adversary can
-- refuse, land without acknowledgement, or fail once. It wraps any 'ObjectOps'
-- (normally the in-memory fake), generalizing the F38 spec's faulting store.
module Nagare.Test.World.Store
  ( faultingObjectOps
  )
where

import Data.IORef
import Nagare.Dsl.Prelude
import Nagare.Inventory.Store.ObjectOps
import Nagare.Test.World.Adversary

faultingObjectOps :: IORef Adversary -> ObjectOps -> ObjectOps
faultingObjectOps adversary base =
  base
    { putObject = \condition name bytes -> do
        fault <- nextFault adversary StorePutCall
        case fault of
          Just PutRefused -> pure (PutUnknown "injected: store write refused before landing")
          Just PutLandedUnacknowledged -> do
            _ <- putObject base condition name bytes
            pure (PutUnknown "injected: store write acknowledgement lost")
          _ -> putObject base condition name bytes
    , getObject = \name -> do
        fault <- nextFault adversary StoreGetCall
        case fault of
          Just GetFailedOnce -> pure (GetUnknown "injected: store read failed")
          _ -> getObject base name
    }
