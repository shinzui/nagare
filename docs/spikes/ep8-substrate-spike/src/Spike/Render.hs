-- | Render a spike 'Deployment' to Knative Service YAML.
--
-- Rules (from EP-6, the fixed golden contract):
--
--   * env entries sorted by variable name (@Data.Map@ is already ordered);
--   * autoscaling annotation /values/ are Strings (rendered quoted: @'0'@);
--   * absent optional fields produce no YAML sub-object at all;
--   * @secretRef@ becomes @valueFrom.secretKeyRef@ with @name@ = the secret
--     and @key@ = the env var's own name.
--
-- Key ordering note: the golden output is NOT alphabetical — inside the
-- autoscaling annotations block @min-scale@ precedes @max-scale@, and in a
-- container @image@/@ports@/@env@/@resources@ follow document order, not sort
-- order. A plain @Data.Yaml.encode@ (which orders object keys by the aeson
-- @KeyMap@'s internal order) cannot reproduce this byte-for-byte, so we render
-- through @Data.Yaml.Pretty.encodePretty@ with an explicit key comparator that
-- imposes the exact golden order. (Recorded in the plan's Decision Log.)
module Spike.Render
  ( renderService
  , renderDomainMapping
  ) where

import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Yaml.Pretty qualified as YP
import Spike.Types

-- | Render to Knative Service YAML bytes. The second argument is the resolved
-- image tag (e.g. @"20260602-120000"@).
renderService :: Deployment -> Text -> BS.ByteString
renderService dep tag = YP.encodePretty knativeConfig (serviceValue dep tag)

-- | Render a DomainMapping if 'depDomain' is set, else 'Nothing'.
renderDomainMapping :: Deployment -> Maybe BS.ByteString
renderDomainMapping dep =
  fmap (YP.encodePretty knativeConfig . domainValue dep) (depDomain dep)

-- ---------------------------------------------------------------------------
-- YAML key ordering

-- | A pretty-print config whose key comparator imposes the golden key order.
knativeConfig :: YP.Config
knativeConfig = YP.setConfCompare keyCompare YP.defConfig

-- | Order keys by a fixed rank (lower first), falling back to alphabetical for
-- any key not in the table. Ranks only need to be distinct /within/ a single
-- object; the same rank may safely be reused across unrelated objects.
keyCompare :: Text -> Text -> Ordering
keyCompare a b = compare (rank a, a) (rank b, b)
  where
    rank :: Text -> Int
    rank k = maybe maxBound id (lookup k ranks)
    ranks :: [(Text, Int)]
    ranks =
      [ ("apiVersion", 0)
      , ("kind", 1)
      , ("metadata", 2)
      , ("spec", 3)
      , -- metadata
        ("name", 0)
      , ("namespace", 1)
      , -- annotations
        ("annotations", 0)
      , ("autoscaling.knative.dev/min-scale", 0)
      , ("autoscaling.knative.dev/max-scale", 1)
      , -- container
        ("containers", 0)
      , ("image", 0)
      , ("ports", 1)
      , ("env", 2)
      , ("resources", 3)
      , ("containerPort", 0)
      , ("value", 1)
      , ("valueFrom", 1)
      , ("secretKeyRef", 0)
      , ("key", 1)
      , ("requests", 0)
      , ("cpu", 0)
      , ("memory", 1)
      , ("template", 0)
      , ("ref", 0)
      ]

-- ---------------------------------------------------------------------------
-- Internal builders

serviceValue :: Deployment -> Text -> A.Value
serviceValue dep tag =
  A.object
    [ "apiVersion" A..= ("serving.knative.dev/v1" :: Text)
    , "kind" A..= ("Service" :: Text)
    , "metadata"
        A..= A.object
          [ "name" A..= depName dep
          , "namespace" A..= depNamespace dep
          ]
    , "spec" A..= A.object ["template" A..= templateValue dep tag]
    ]

templateValue :: Deployment -> Text -> A.Value
templateValue dep tag =
  A.object
    [ "metadata" A..= templateMeta dep
    , "spec" A..= A.object ["containers" A..= [containerValue dep tag]]
    ]

templateMeta :: Deployment -> A.Value
templateMeta dep =
  case depScale dep of
    Nothing -> A.object []
    Just s ->
      A.object
        [ "annotations"
            A..= A.object
              [ "autoscaling.knative.dev/min-scale" A..= show (scaleMin s)
              , "autoscaling.knative.dev/max-scale" A..= show (scaleMax s)
              ]
        ]

containerValue :: Deployment -> Text -> A.Value
containerValue dep tag =
  A.object $
    concat
      [
        [ "image" A..= (depImage dep <> ":" <> tag)
        , "ports" A..= [A.object ["containerPort" A..= depPort dep]]
        ]
      , if Map.null (depEnv dep)
          then []
          else [("env", envValue (depEnv dep))]
      , case depResources dep of
          Nothing -> []
          Just r -> [("resources", resourcesValue r)]
      ]

envValue :: Map Text EnvVar -> A.Value
envValue m = A.toJSON (map entry (Map.toAscList m))
  where
    entry :: (Text, EnvVar) -> A.Value
    entry (name, EnvLiteral v) =
      A.object
        [ "name" A..= name
        , "value" A..= v
        ]
    entry (name, EnvSecretRef secret) =
      A.object
        [ "name" A..= name
        , "valueFrom"
            A..= A.object
              [ "secretKeyRef"
                  A..= A.object
                    [ "name" A..= secret
                    , "key" A..= name
                    ]
              ]
        ]

resourcesValue :: Resources -> A.Value
resourcesValue r =
  A.object
    [ "requests"
        A..= A.object
          ( catMaybes
              [ fmap ("cpu" A..=) (resCpu r)
              , fmap ("memory" A..=) (resMemory r)
              ]
          )
    ]
  where
    catMaybes = foldr (\mx acc -> maybe acc (: acc) mx) []

domainValue :: Deployment -> Text -> A.Value
domainValue dep domain =
  A.object
    [ "apiVersion" A..= ("serving.knative.dev/v1beta1" :: Text)
    , "kind" A..= ("DomainMapping" :: Text)
    , "metadata"
        A..= A.object
          [ "name" A..= domain
          , "namespace" A..= depNamespace dep
          ]
    , "spec"
        A..= A.object
          [ "ref"
              A..= A.object
                [ "apiVersion" A..= ("serving.knative.dev/v1" :: Text)
                , "kind" A..= ("Service" :: Text)
                , "name" A..= depName dep
                ]
          ]
    ]
