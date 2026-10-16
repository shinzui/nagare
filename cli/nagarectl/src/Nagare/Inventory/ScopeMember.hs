-- | Decoding one immutable scope member. The planning history and the
-- recorded-state reader share these checks: the member is present, its
-- bytes have the digest the head names, it decodes, and it is the scope the
-- head names.
module Nagare.Inventory.ScopeMember
  ( decodeScopeMember
  )
where

import Data.ByteString (ByteString)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Store (StoreError (StoreInvalidObject), scopeKey)
import Nagare.Resource.Inventory (ScopeDeclaration, scopeId)
import Nagare.Resource.Types (ContentDigest, ScopeId)
import Nagare.Resource.Wire (decodeScope)

decodeScopeMember :: ScopeId -> ContentDigest -> Maybe ByteString -> Either StoreError ScopeDeclaration
decodeScopeMember scope digest found = do
  bytes <- maybe (Left (StoreInvalidObject key "scope member is missing")) Right found
  unless (contentDigest bytes == digest) (Left (StoreInvalidObject key "scope member digest mismatch"))
  declaration <- first (StoreInvalidObject key . T.pack . show) (decodeScope bytes)
  unless (scopeId declaration == scope) (Left (StoreInvalidObject key "scope member identity mismatch"))
  pure declaration
  where
    key = scopeKey digest
