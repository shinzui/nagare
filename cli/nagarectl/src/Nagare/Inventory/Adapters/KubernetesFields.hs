-- | Whether an observed Kubernetes object matches the fields of its retained
-- desired object. Internal implementation behind
-- "Nagare.Inventory.Adapters.KubernetesRuntime", which re-exports it.
module Nagare.Inventory.Adapters.KubernetesFields
  ( desiredFieldsMatch
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Dsl.Quantity (canonicalQuantity)

-- | Compare only fields present in the retained desired object. Server-added
-- metadata, defaults and status do not count as drift. Arrays stay ordered;
-- this deliberately reports uncertain associative-list reorderings as drift.
desiredFieldsMatch :: Value -> Value -> Bool
desiredFieldsMatch desired observed
  | delegatedServingWebhook desired =
      servingWebhookRulesMatch desired observed
        && go [] (withoutWebhookRules desired) observed
  | otherwise = go [] desired observed
  where
    delegatedServingWebhook (Object root) =
      KM.lookup "apiVersion" root == Just (String "admissionregistration.k8s.io/v1")
        && KM.lookup "kind" root
          `elem` [Just (String "MutatingWebhookConfiguration"), Just (String "ValidatingWebhookConfiguration")]
        && case KM.lookup "metadata" root of
          Just (Object metadata) ->
            KM.lookup "name" metadata
              `elem` [Just (String "webhook.serving.knative.dev"), Just (String "validation.webhook.serving.knative.dev")]
          _ -> False
    delegatedServingWebhook _ = False
    withoutWebhookRules (Object root) = case KM.lookup "webhooks" root of
      Just hooks -> Object (KM.insert "webhooks" (stripWebhooks hooks) root)
      Nothing -> Object root
    withoutWebhookRules value = value
    stripWebhooks (Array webhooks) = Array (fmap stripOne webhooks)
    stripWebhooks value = value
    stripOne (Object webhook) = Object (KM.delete "rules" webhook)
    stripOne value = value
    servingWebhookRulesMatch (Object desiredRoot) (Object observedRoot) =
      case (KM.lookup "webhooks" desiredRoot, KM.lookup "webhooks" observedRoot) of
        (Just (Array desiredHooks), Just (Array observedHooks)) ->
          not (V.null desiredHooks)
            && V.length desiredHooks == V.length observedHooks
            && and (V.toList (V.zipWith sameRules desiredHooks observedHooks))
        _ -> False
    servingWebhookRulesMatch _ _ = False
    sameRules (Object desiredHook) (Object observedHook) =
      KM.lookup "name" desiredHook == KM.lookup "name" observedHook
        && case (KM.lookup "rules" desiredHook, KM.lookup "rules" observedHook) of
          (Just (Array desiredRules), Just (Array observedRules)) ->
            not (V.null desiredRules)
              && not (V.null observedRules)
              && all validRule (V.toList observedRules)
              && groups desiredRules == groups observedRules
              && resources desiredRules == resources observedRules
              && operations desiredRules == operations observedRules
              && scopes desiredRules == scopes observedRules
          _ -> False
    sameRules _ _ = False
    groups = Set.unions . map (textSet "apiGroups") . V.toList
    resources rules =
      Set.fromList
        [ maybe item id (T.stripSuffix "/status" item)
        | rule <- V.toList rules
        , item <- Set.toList (textSet "resources" rule)
        ]
    operations = Set.unions . map (textSet "operations") . V.toList
    scopes = Set.fromList . mapMaybe (ruleText "scope") . V.toList
    validRule rule =
      not (Set.null (textSet "apiGroups" rule))
        && not (Set.null (textSet "apiVersions" rule))
        && not (Set.null (textSet "operations" rule))
        && not (Set.null (textSet "resources" rule))
        && isJust (ruleText "scope" rule)
    ruleText key (Object value) = case KM.lookup key value of
      Just (String item) -> Just item
      _ -> Nothing
    ruleText _ _ = Nothing
    textSet key (Object value) = case KM.lookup key value of
      Just (Array items) -> Set.fromList [item | String item <- V.toList items]
      _ -> Set.empty
    textSet _ _ = Set.empty
    go path (Object desired) (Object observed) =
      all
        ( \(key, value) -> case KM.lookup key observed of
            Just actual -> go (Key.toText key : path) value actual
            Nothing ->
              ( key == "value" && value == String "" && case path of
                  "env" : _ -> KM.lookup "valueFrom" observed == Nothing
                  _ -> False
              )
                || ( key == "readOnly" && value == Bool False && case path of
                       "volumeMounts" : _ -> True
                       _ -> False
                   )
                || ( key `elem` ["hostAliases", "volumes"]
                       && value `elem` [Null, Array V.empty]
                       && path == ["spec", "template", "spec"]
                   )
        )
        (KM.toList desired)
    go path (Array desired) (Array observed) =
      length desired == length observed && and (zipWith (go path) (foldr (:) [] desired) (foldr (:) [] observed))
    -- G7, RES-4 U7 (E11, E15): the API server stores a resource list's
    -- quantities in canonical form, so they compare in it. Any other string
    -- keeps exact equality, so ConfigMap data is never normalised.
    go (_ : list : parent : _) (String declared) (String stored)
      | (list `elem` ["limits", "requests"] && parent == "resources") || (list == "hard" && parent == "spec") =
          declared == stored || maybe False (\canonical -> Just canonical == canonicalQuantity stored) (canonicalQuantity declared)
    go _ desired observed = desired == observed
