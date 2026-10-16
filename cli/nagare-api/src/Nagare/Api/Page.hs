{-# LANGUAGE DataKinds #-}

-- | The Relay page arguments every growing list takes: @first@/@after@
-- forward, @last@/@before@ backward. They are ordinary query parameters so
-- that a malformed or oversized page is an RFC 9457 problem, like every other
-- Nagare error, rather than the relay combinator's own error body.
module Nagare.Api.Page
  ( Paginated
  , PageSize (..)
  , defaultPageSize
  , maximumPageSize
  )
where

import Data.OpenApi (OpenApiType (..), OpenApiTypeValue (..), ToParamSchema (..), maximum_, minimum_, type_)
import Nagare.Contract.Prelude
import Servant.API (Description, FromHttpApiData, Optional, QueryParam', Strict, ToHttpApiData, (:>))

-- | A requested page size. Its range is checked when the page request is
-- validated, so an out-of-range size is a problem, not a clamp.
newtype PageSize = PageSize Int
  deriving stock (Eq, Show)
  deriving newtype (FromHttpApiData, ToHttpApiData)

instance ToParamSchema PageSize where
  toParamSchema _ =
    mempty
      & type_
      ?~ OpenApiTypeSingle OpenApiInteger
      & minimum_
      ?~ 0
      & maximum_
      ?~ fromIntegral maximumPageSize

type Paginated sub =
  QueryParam' '[Optional, Strict, Description "Forward page size, 0 to 100; 50 when neither first nor last is given. Not with last or before."] "first" PageSize
    :> QueryParam' '[Optional, Strict, Description "Opaque cursor: items after this position."] "after" Text
    :> QueryParam' '[Optional, Strict, Description "Backward page size, 0 to 100. Not with first or after."] "last" PageSize
    :> QueryParam' '[Optional, Strict, Description "Opaque cursor: items before this position."] "before" Text
    :> sub

defaultPageSize, maximumPageSize :: Int
defaultPageSize = 50
maximumPageSize = 100
