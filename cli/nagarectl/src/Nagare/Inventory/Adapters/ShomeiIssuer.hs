-- | EP-264: what a reviewed Shomei Deployment says about its token issuer.
-- A URL issuer turns Shomei into an OIDC provider and refuses every token
-- minted under another issuer, so the operation's summary names the issuer and
-- its effect on signed-in browsers, derived from the reviewed bytes as the En
-- tenant proof ('Nagare.Inventory.Adapters.EnTenants.enDeclaredTenants') is.
module Nagare.Inventory.Adapters.ShomeiIssuer
  ( shomeiDeclaredIssuer
  , shomeiIssuerClause
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude

-- | The @https@ issuer a reviewed native object declares, when it is the
-- shomei Deployment in @nagare-system@; otherwise 'Nothing'.
shomeiDeclaredIssuer :: ByteString -> Maybe Text
shomeiDeclaredIssuer native = do
  Object root <- either (const Nothing) Just (eitherDecodeStrict native)
  guard (KM.lookup "kind" root == Just (String "Deployment"))
  Object metadata <- KM.lookup "metadata" root
  guard (KM.lookup "name" metadata == Just (String "shomei"))
  guard (KM.lookup "namespace" metadata == Just (String "nagare-system"))
  Object spec <- KM.lookup "spec" root
  Object template <- KM.lookup "template" spec
  Object podSpec <- KM.lookup "spec" template
  Array containers <- KM.lookup "containers" podSpec
  listToMaybe
    [ issuer
    | Object container <- toList containers
    , KM.lookup "name" container == Just (String "shomei")
    , Just (Array env) <- [KM.lookup "env" container]
    , Object variable <- toList env
    , KM.lookup "name" variable == Just (String "SHOMEI_ISSUER")
    , Just (String issuer) <- [KM.lookup "value" variable]
    , "https://" `T.isPrefixOf` issuer
    ]

-- | The summary clause for an operation on such a Deployment.
shomeiIssuerClause :: ByteString -> Text
shomeiIssuerClause native = case shomeiDeclaredIssuer native of
  Nothing -> ""
  Just issuer ->
    "; Shomei issuer "
      <> issuer
      <> " with OIDC enabled: tokens minted under any other issuer are refused, so a signed-in browser renews its session and may be asked to sign in once"
