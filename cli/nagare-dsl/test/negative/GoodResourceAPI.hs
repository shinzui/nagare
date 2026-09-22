{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module GoodResourceAPI where

import Data.Aeson (Value (Null))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Reference
import Nagare.Resource.Types
import Nagare.Resource.Wire

context :: Either Text ContextId
context = mkContextId "stable-context"

image :: ResourceId -> Name -> CapabilityRef 'OciImage
image r k = outputRef OciImageW r k [] Public

secret :: ByteString -> RawCredential
secret = rawCredential

jsonControl :: Value
jsonControl = Null
