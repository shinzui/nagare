{-# LANGUAGE PackageImports #-}

-- | Render a 'StaticSite' to the three artifacts a static deploy needs:
--
--   * the generated Nginx configuration that serves the built files
--     ('renderNginxConfig'), with redirects applied before header rules and the
--     cache policy turned into @Cache-Control@ headers;
--   * the Knative @Service@ YAML that runs the Nginx image ('renderStaticService');
--   * one @DomainMapping@ YAML per configured custom domain
--     ('renderStaticDomainMappings').
--
-- The Knative key ordering matches the cluster contract used by
-- 'Nagare.Dsl.Render' (apiVersion, kind, name-first metadata, then spec). The
-- Nginx config is deterministic: rules are emitted in declaration order so the
-- golden tests are stable.
module Nagare.Dsl.Static.Render
  ( StaticDeployContext (..)
  , renderNginxConfig
  , renderStaticService
  , renderStaticDomainMappings
  ) where

import Nagare.Dsl.Prelude hiding ((.=))

import "generic-lens" Data.Generics.Labels ()

import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Yaml.Pretty qualified as YP
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (Domain, domainText, imageRefText, namespaceText)

-- | What a deploy knows beyond the 'StaticSite' itself: the resolved image tag
-- (e.g. @"20260607-120000"@) and an optional preview name. When @previewName@ is
-- set, it replaces the site name as the Knative Service name so a preview deploy
-- lands on a separate Service; production deploys leave it 'Nothing'.
data StaticDeployContext = StaticDeployContext
  { imageTag :: Text
  , previewName :: Maybe Text
  }
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- Service name resolution

-- | The Knative Service name for this deploy: the preview name when set,
-- otherwise the site's own name.
serviceNameFor :: StaticSite -> StaticDeployContext -> Text
serviceNameFor site ctx = fromMaybe (siteNameText (site ^. #name)) (previewName ctx)

-- ---------------------------------------------------------------------------
-- Nginx config

-- | The directory the Nginx image serves the static files from.
nginxRoot :: Text
nginxRoot = "/usr/share/nginx/html"

-- | Render the Nginx server config for a static site. The block order is fixed:
-- redirect rules first, then per-path header rules, then the immutable-asset
-- cache location, then the catch-all that serves files (falling back to the 404
-- page when configured, or to @index.html@ for SPA routing otherwise).
renderNginxConfig :: StaticSite -> ByteString
renderNginxConfig site =
  TE.encodeUtf8 . Text.unlines $
    [ "server {"
    , "    listen 8080;"
    , "    server_name _;"
    , "    root " <> nginxRoot <> ";"
    , "    index index.html;"
    ]
      <> concatMap redirectBlock (site ^. #redirects)
      <> concatMap headerBlock (site ^. #headers)
      <> cacheBlock (site ^. #cache)
      <> rootBlock (site ^. #notFound) (site ^. #cache)
      <> notFoundBlock (site ^. #notFound)
      <> ["}"]

-- | An exact-match redirect location: @location = /from { return <status> /to; }@.
redirectBlock :: RedirectRule -> [Text]
redirectBlock r =
  [ ""
  , "    # redirect " <> (r ^. #from) <> " -> " <> (r ^. #to) <> " (" <> tshow (r ^. #status) <> ")"
  , "    location = " <> (r ^. #from) <> " {"
  , "        return " <> tshow (r ^. #status) <> " " <> (r ^. #to) <> ";"
  , "    }"
  ]

-- | A header rule location: add the response header for requests under @path@.
headerBlock :: HeaderRule -> [Text]
headerBlock h =
  [ ""
  , "    location " <> (h ^. #path) <> " {"
  , "        add_header " <> (h ^. #name) <> " " <> quoted (h ^. #value) <> " always;"
  , "        try_files $uri $uri/ =404;"
  , "    }"
  ]

-- | The immutable-asset cache location, emitted only when the policy enables it.
cacheBlock :: CachePolicy -> [Text]
cacheBlock cp
  | immutableAssets cp =
      [ ""
      , "    # immutable fingerprinted assets"
      , "    location ~* \\.(?:js|css|woff2?|png|jpe?g|gif|svg|ico|webp|avif)$ {"
      , "        add_header Cache-Control \"public, max-age=31536000, immutable\" always;"
      , "        try_files $uri =404;"
      , "    }"
      ]
  | otherwise = []

-- | The catch-all location. @try_files@ falls back to the 404 page when one is
-- configured, otherwise to @index.html@ (SPA routing). A configured default
-- max-age becomes a @Cache-Control@ header here.
rootBlock :: Maybe FilePathText -> CachePolicy -> [Text]
rootBlock mNotFound cp =
  [ ""
  , "    location / {"
  ]
    <> maybeMaxAge
    <> [ "        try_files $uri $uri/ $uri.html " <> fallback <> ";"
       , "    }"
       ]
  where
    fallback = case mNotFound of
      Just _ -> "=404"
      Nothing -> "/index.html"
    maybeMaxAge = case defaultMaxAge cp of
      Just n ->
        ["        add_header Cache-Control \"public, max-age=" <> tshow n <> "\" always;"]
      Nothing -> []

-- | The @error_page@ + internal 404 location, emitted only when a 404 page is
-- configured.
notFoundBlock :: Maybe FilePathText -> [Text]
notFoundBlock Nothing = []
notFoundBlock (Just p) =
  [ ""
  , "    error_page 404 /" <> filePathText p <> ";"
  , "    location = /" <> filePathText p <> " {"
  , "        internal;"
  , "    }"
  ]

quoted :: Text -> Text
quoted t = "\"" <> t <> "\""

-- ---------------------------------------------------------------------------
-- Knative Service + DomainMapping

-- | Render the Knative Service that runs the static site's Nginx image at the
-- resolved tag, listening on container port 8080.
renderStaticService :: StaticSite -> StaticDeployContext -> ByteString
renderStaticService site ctx = YP.encodePretty knativeConfig (serviceValue site ctx)

-- | Render one DomainMapping YAML document per configured custom domain, each
-- pointing at this deploy's Service.
renderStaticDomainMappings :: StaticSite -> StaticDeployContext -> [ByteString]
renderStaticDomainMappings site ctx =
  map (YP.encodePretty knativeConfig . domainMappingValue site ctx) (site ^. #domains)

serviceValue :: StaticSite -> StaticDeployContext -> Value
serviceValue site ctx =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
    , "kind" .= ("Service" :: Text)
    , "metadata"
        .= namespacedMeta (serviceNameFor site ctx) (namespaceText (site ^. #namespace))
    , "spec" .= object ["template" .= templateValue site ctx]
    ]

templateValue :: StaticSite -> StaticDeployContext -> Value
templateValue site ctx =
  object ["spec" .= object ["containers" .= toJSON [containerValue site ctx]]]

containerValue :: StaticSite -> StaticDeployContext -> Value
containerValue site ctx =
  object
    [ "image" .= (imageRefText (site ^. #image) <> ":" <> imageTag ctx)
    , "ports" .= toJSON [object ["containerPort" .= (8080 :: Int)]]
    ]

domainMappingValue :: StaticSite -> StaticDeployContext -> Domain -> Value
domainMappingValue site ctx d =
  object
    [ "apiVersion" .= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" .= ("DomainMapping" :: Text)
    , "metadata"
        .= namespacedMeta (domainText d) (namespaceText (site ^. #namespace))
    , "spec"
        .= object
          [ "ref"
              .= object
                [ "apiVersion" .= ("serving.knative.dev/v1" :: Text)
                , "kind" .= ("Service" :: Text)
                , "name" .= serviceNameFor site ctx
                ]
          ]
    ]

namespacedMeta :: Text -> Text -> Value
namespacedMeta n ns = object ["name" .= n, "namespace" .= ns]

-- ---------------------------------------------------------------------------
-- YAML key ordering (mirrors the cluster contract in Nagare.Dsl.Render)

knativeConfig :: YP.Config
knativeConfig = YP.setConfCompare keyCompare YP.defConfig

keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("name", 2)
      , ("namespace", 3)
      , ("metadata", 4)
      , ("spec", 5)
      , ("template", 0)
      , ("containers", 0)
      , ("image", 0)
      , ("ports", 1)
      , ("containerPort", 0)
      , ("ref", 0)
      ]

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
