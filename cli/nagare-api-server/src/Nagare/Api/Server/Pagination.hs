-- | Keyset Relay pages over a list sorted by one unique text key (a full
-- scope or resource ID).
--
-- A cursor carries the complete ordering key and a fingerprint of the
-- context, endpoint, filter values and sort definition. A malformed or
-- foreign cursor is rejected before any scope is hydrated. The fingerprint
-- deliberately omits the head revision: across heads the next page is the
-- items strictly after (or before) the key in the new head, so a walk that
-- must be consistent compares @Nagare-Head-Revision@ and restarts.
module Nagare.Api.Server.Pagination
  ( PageArgs (..)
  , Pager (..)
  , pager
  , pageOf
  )
where

import Data.Bits (xor)
import Data.ByteString qualified as BS
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import Nagare.Api.Page (PageSize (..))
import Nagare.Api.Page qualified as Page
import Nagare.Contract.Prelude
import Nagare.Contract.Problem (ProblemDetails, invalidCursor, invalidPage, problemFor)
import Relay.Pagination
  ( Connection (..)
  , Cursor
  , CursorPayload (..)
  , Direction (..)
  , Edge (..)
  , KeyValue (..)
  , PageConfig (..)
  , PageInfo (..)
  , PageRequest (..)
  , PageRequestError (..)
  , cursorFromText
  , cursorVersion
  , decodeCursor
  , encodeCursor
  , mkPageRequest
  )

-- | The four Relay arguments as the route received them.
data PageArgs = PageArgs
  { firstSize :: !(Maybe PageSize)
  , afterCursor :: !(Maybe Text)
  , lastSize :: !(Maybe PageSize)
  , beforeCursor :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | A validated page request and the key its cursor names.
data Pager = Pager
  { fingerprint :: !Word32
  , request :: !PageRequest
  , boundary :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Validate the arguments for one endpoint. @scopeText@ names the context,
-- endpoint and filter values the cursor is bound to.
pager :: Text -> PageArgs -> Either ProblemDetails Pager
pager scopeText (PageArgs firstArg afterArg lastArg beforeArg) = do
  parsedAfter <- traverse (parseCursor "after") afterArg
  parsedBefore <- traverse (parseCursor "before") beforeArg
  pageRequest <-
    first pageProblem $
      mkPageRequest
        (PageConfig Page.defaultPageSize Page.maximumPageSize)
        (size <$> firstArg)
        parsedAfter
        (size <$> lastArg)
        parsedBefore
  key <- traverse (cursorKey (if isJust parsedAfter then "after" else "before")) (requestCursor pageRequest)
  pure (Pager fingerprintValue pageRequest key)
  where
    fingerprintValue = fnv1a (TE.encodeUtf8 ("nagare-admin|v1|" <> scopeText <> "|key asc"))
    size (PageSize value) = value
    parseCursor parameter value =
      first (const (problemFor invalidCursor (parameter <> " is not a cursor of this API"))) (cursorFromText value)
    cursorKey parameter cursor = case decodeCursor fingerprintValue cursor of
      Right (CursorPayload _ _ [KvText key]) -> Right key
      _ -> Left (problemFor invalidCursor (parameter <> " was issued for another list, filter or context"))
    pageProblem = \case
      FirstAndLastBothGiven -> problemFor invalidPage "first and last cannot be combined"
      AfterAndBeforeBothGiven -> problemFor invalidPage "after and before cannot be combined"
      FirstWithBefore -> problemFor invalidPage "first cannot be combined with before"
      LastWithAfter -> problemFor invalidPage "last cannot be combined with after"
      NegativePageSize _ -> problemFor invalidPage "a page size cannot be negative"
      PageSizeTooLarge _ allowed -> problemFor invalidPage ("a page size cannot exceed " <> Text.pack (show allowed))

-- | The page of @items@, which must be sorted by @keyOf@ with unique keys.
-- Edges are in canonical order for both directions.
pageOf :: Pager -> (a -> Text) -> [a] -> Connection a
pageOf (Pager fingerprintValue pageRequest key) keyOf items =
  Connection (map edge chunk) (PageInfo hasNext hasPrevious (cursorOf <$> safeHead chunk) (cursorOf <$> safeLast chunk))
  where
    PageRequest {pageSize = size, direction = way} = pageRequest
    (chunk, hasNext, hasPrevious) = case way of
      Forward ->
        let rest = maybe items (\k -> filter ((> k) . keyOf) items) key
         in (take size rest, length rest > size, maybe False (\k -> any ((<= k) . keyOf) items) key)
      Backward ->
        let earlier = maybe items (\k -> filter ((< k) . keyOf) items) key
            dropped = length earlier - size
         in (drop (max 0 dropped) earlier, maybe False (\k -> any ((>= k) . keyOf) items) key, dropped > 0)
    edge item = Edge item (cursorOf item)
    cursorOf item = encodeCursor (CursorPayload cursorVersion fingerprintValue [KvText (keyOf item)])
    safeHead = \case
      [] -> Nothing
      value : _ -> Just value
    safeLast values = safeHead (reverse values)

requestCursor :: PageRequest -> Maybe Cursor
requestCursor PageRequest {cursor = position} = position

-- | 32-bit FNV-1a.
fnv1a :: BS.ByteString -> Word32
fnv1a = BS.foldl' (\hash byte -> (hash `xor` fromIntegral byte) * 16777619) 2166136261
