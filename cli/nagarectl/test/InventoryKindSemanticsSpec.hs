-- | EP-182 M1: every in-line row of the kind table states its kind's API
-- semantics, and those claims agree with traces recorded from a real API
-- server (k3s v1.34.6, Knative Serving 1.22) by
-- @docs/audits/k8s-semantics-2026-10-06/experiments/record-traces.sh@.
-- A column with no trace evidence is a failure, not a pass.
module InventoryKindSemanticsSpec (inventoryKindSemanticsTests) where

import Data.Aeson (Value (..), eitherDecodeFileStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Test.World.Kinds
import Test.Tasty
import Test.Tasty.HUnit

-- | Read relative to the package directory, as the suite's other fixtures are.
tracesPath :: FilePath
tracesPath = "test/fixtures/kubernetes-semantics/traces.json"

data Step = Step
  { experiment :: !Text
  , kindToken :: !Text
  , label :: !Text
  , action :: !Value
  , observation :: !Value
  }
  deriving stock (Show)

inventoryKindSemanticsTests :: TestTree
inventoryKindSemanticsTests =
  testGroup
    "kind semantics"
    [ testCase "the table agrees with the recorded traces" $ do
        steps <- loadSteps
        let found =
              concat
                [ disagreements steps selected semantics'
                | row <- kindTable
                , row ^. #status == InLine
                , Just selected <- [kubernetesKind row]
                , Just semantics' <- [row ^. #semantics]
                ]
        assertBool (T.unpack (T.unlines found)) (null found)
    , testCase "every in-line Kubernetes row has semantics, and no documented limit claims any" $ do
        [kubernetesKind row | row <- kindTable, row ^. #status == InLine, isNothing (row ^. #semantics)] @?= []
        [kubernetesKind row | row <- kindTable, row ^. #status /= InLine, isJust (row ^. #semantics)] @?= []
    , testCase "each row's readiness agrees with its readiness model" $
        [ kubernetesKind row
        | row <- kindTable
        , Just semantics' <- [row ^. #semantics]
        , row ^. #readiness /= readinessOf (semantics' ^. #readinessModel)
        ]
          @?= []
    ]
  where
    readinessOf model = case model of
      NoReadinessModel -> NoReadiness
      JobTerminal -> CanFail
      _ -> CanBeUnready

loadSteps :: IO [Step]
loadSteps =
  eitherDecodeFileStrict' tracesPath >>= \case
    Left err -> assertFailure ("cannot read " <> tracesPath <> ": " <> err) >> pure []
    Right document -> case field "steps" document of
      Array values -> pure (map toStep (toList values))
      _ -> assertFailure (tracesPath <> " has no steps") >> pure []
  where
    toStep value = Step (text (field "experiment" value)) (text (field "kind" value)) (text (field "step" value)) (field "action" value) (field "observation" value)

-- | Each column the table claims for one kind, against the column derived
-- from the traces; a message per disagreement or missing evidence.
disagreements :: [Step] -> (Text, Text) -> KindSemantics -> [Text]
disagreements steps selected semantics' =
  concat
    [ column "generationRule" (semantics' ^. #generationRule) generationRule
    , column "tracksObservedGeneration" (semantics' ^. #tracksObservedGeneration) tracksObservedGeneration
    , column "hasStatusSubresource" (semantics' ^. #hasStatusSubresource) hasStatusSubresource
    , column "readinessModel" (semantics' ^. #readinessModel) readinessModel
    , column "churnSource" (semantics' ^. #churnSource) churnSource
    , column "deletionRule" (semantics' ^. #deletionRule) deletionRule
    ]
  where
    token = if selected == ("serving.knative.dev", "service") then "ksvc" else snd selected
    column :: (Eq a, Show a) => Text -> a -> Either Text a -> [Text]
    column name claimed = \case
      Left missing -> [name' name <> ": no trace evidence (" <> missing <> ")"]
      Right derived
        | derived == claimed -> []
        | otherwise -> [name' name <> ": the table says " <> tshow claimed <> ", the traces say " <> tshow derived]
    name' name = T.pack (show selected) <> " " <> name
    of' experiment' = [step | step <- steps, experiment step == experiment', kindToken step == token]
    observed experiment' label' = maybe (Left (experiment' <> " " <> label')) (Right . observation) (find ((== label') . label) (of' experiment'))

    generationRule = do
      created <- observed "E1" "create"
      if field "generation" created == Null
        then Right NoGeneration
        else do
          before <- observed "E1" "no-op apply"
          annotated <- observed "E1" "annotate"
          labelled <- observed "E1" "label"
          changed <- observed "E1" "spec change"
          case () of
            _
              | moved "generation" before annotated -> Right SpecAndAnnotations
              | moved "generation" labelled changed -> Right SpecOnly
              | otherwise -> Left "E1: generation present but moved on neither an annotation nor a spec write"

    tracksObservedGeneration = (/= Null) . field "observedGeneration" <$> observed "E1" "settle"

    hasStatusSubresource = do
      discovered <- maybe (Left "E0 status subresources") (Right . observation) (find ((== "E0") . experiment) steps)
      plural <- maybe (Left ("no plural for " <> token)) Right (lookup (snd selected) plurals)
      pure (any (matches plural) (arrayOf discovered))
      where
        matches plural entry = groupOf (text (field "groupVersion" entry)) == fst selected && text (field "resource" entry) == plural <> "/status"
        groupOf groupVersion = case T.breakOn "/" groupVersion of
          (_, "") -> ""
          (group', _) -> group'

    readinessModel = case reverse [observation step | step <- of' "E1", label step == "settle"] of
      [] -> Left "E1 settle"
      settled : _
        | hasCondition "Ready" -> Right KnativeConditions
        | hasCondition "Available" -> Right DeploymentRollout
        | hasCondition "Complete" || hasCondition "Failed" -> Right JobTerminal
        | field "counters" settled `notElem` [Null, Object KM.empty] -> Right StatefulSetRollout
        | otherwise -> Right NoReadinessModel
        where
          hasCondition condition = KM.member (Key.fromText condition) (objectOf (field "conditions" settled))

    churnSource = case of' "E10" of
      [] -> Left "E10"
      watched -> case [label step | step <- watched, moved "resourceVersion" (field "before" (action step)) (observation step)] of
        [] -> Right NoChurn
        churned
          | token == "cronjob" -> if all ("a running schedule" `T.isPrefixOf`) churned then Right ScheduleTicks else Left ("a suspended CronJob churned: " <> T.intercalate ", " churned)
          | token == "resourcequota" -> Right PodChanges
          | otherwise -> Left ("churned while unattended: " <> T.intercalate ", " churned)

    deletionRule
      | Right blocked <- observed "E7" "Orphan delete, after 30s"
      , present blocked && held blocked "orphan" =
          case observed "E7" "Background delete, after 10s" of
            Right finished | not (present finished) -> Right OrphanBlocked
            _ -> Left "E7: an Orphan delete held, with no Background delete that completes"
      | Right inUse <- observed "E7" "Orphan delete, after 10s"
      , present inUse && held inUse "kubernetes.io/pvc-protection" =
          case observed "E7" "after its consumer is deleted" of
            Right released | not (present released) -> Right HeldWhileInUse
            _ -> Left "E7: a delete held while in use, never released"
      | Right started <- observed "E12" "delete with contents, immediately"
      , present started && field "deletionTimestamp" started == Bool True =
          case observed "E12" "delete with contents, settled" of
            Right settled | not (present settled) -> Right HeldUntilEmpty
            _ -> Left "E12: a delete held until empty, never completed"
      | otherwise = case [observation step | step <- of' "E14" <> of' "E7", "delete, after" `T.isInfixOf` label step] of
          [] -> Left "E14 or E7 delete"
          afterwards
            | all (not . present) afterwards -> Right Immediate
            | otherwise -> Left "a delete left the object present with no held rule to explain it"

    moved key earlier later = field key earlier /= field key later
    present value = field "present" value == Bool True
    held value finalizer = String finalizer `elem` arrayOf (field "finalizers" value) && field "deletionTimestamp" value == Bool True

plurals :: [(Text, Text)]
plurals =
  [ ("configmap", "configmaps")
  , ("secret", "secrets")
  , ("serviceaccount", "serviceaccounts")
  , ("role", "roles")
  , ("rolebinding", "rolebindings")
  , ("networkpolicy", "networkpolicies")
  , ("service", "services")
  , ("resourcequota", "resourcequotas")
  , ("namespace", "namespaces")
  , ("persistentvolumeclaim", "persistentvolumeclaims")
  , ("deployment", "deployments")
  , ("statefulset", "statefulsets")
  , ("cronjob", "cronjobs")
  , ("job", "jobs")
  , ("domainmapping", "domainmappings")
  ]

field :: Text -> Value -> Value
field key = \case
  Object fields -> fromMaybe Null (KM.lookup (Key.fromText key) fields)
  _ -> Null

text :: Value -> Text
text = \case
  String value -> value
  _ -> ""

arrayOf :: Value -> [Value]
arrayOf = \case
  Array values -> toList values
  _ -> []

objectOf :: Value -> KM.KeyMap Value
objectOf = \case
  Object fields -> fields
  _ -> KM.empty

tshow :: (Show a) => a -> Text
tshow = T.pack . show
