{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
module GoodResourceAPI where
import Data.Text (Text)
import Data.Aeson (Value (Null))
import Nagare.Resource.Types
import Nagare.Resource.Reference
import Nagare.Resource.Policy
import Nagare.Resource.Inventory
import Nagare.Resource.Wire
import Data.ByteString (ByteString)
context :: Either Text ContextId
context = mkContextId "stable-context"
image :: ResourceId -> Name -> CapabilityRef 'OciImage
image r k = outputRef OciImageW r k [] Public
secret :: ByteString -> RawCredential
secret = rawCredential
jsonControl :: Value
jsonControl = Null
