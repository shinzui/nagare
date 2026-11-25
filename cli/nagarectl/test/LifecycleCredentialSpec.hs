-- | EP-235 M2: the lifecycle worker's local object-store user credential is
-- a template filled at creation with the user name and a fresh secret, and
-- observation compares only its key set.
module LifecycleCredentialSpec
  ( lifecycleCredentialTests
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Database.Secret (b64decode)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, generatedCredentialTemplate, materializeCredential, materializeMinioUserCopyWith, minioUserCopyKind, minioUserCredentialKind)
import Nagare.Inventory.KubernetesTransport (KubernetesRuntimeConfig (..))
import Nagare.Resource.Types (mkContextId)
import Nagare.Resource.Wire (canonicalValue)
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty
import Test.Tasty.HUnit

lifecycleCredentialTests :: TestTree
lifecycleCredentialTests =
  testGroup
    "Lifecycle worker credential"
    [ testCase "the object-store user template is filled with its user and a fresh secret, and compared by keys" $ do
        let native = template "nagare-events-minio" (object [])
        generatedCredentialTemplate native @?= Right True
        filled <- materializeCredential native >>= either (assertFailure . T.unpack) pure
        value <- either (assertFailure . ("filled credential: " <>)) pure (eitherDecodeStrict (TE.encodeUtf8 filled))
        case value of
          Object root | Just (Object fields) <- KM.lookup "data" root -> do
            (KM.lookup "AWS_ACCESS_KEY_ID" fields >>= text >>= either (const Nothing) Just . b64decode) @?= Just "nagare-events-minio"
            fmap T.length (KM.lookup "AWS_SECRET_ACCESS_KEY" fields >>= text >>= either (const Nothing) Just . b64decode) @?= Just 64
            credentialDataMatches (parsed native) value @?= True
          _ -> assertFailure "the filled credential has no data"
        again <- materializeCredential native >>= either (assertFailure . T.unpack) pure
        assertBool "each creation draws a fresh secret" (again /= filled)
    , testCase "a template outside nagare-system, with data, or without a user is refused" $ do
        assertBool "another namespace" (isLeft (minioUserCredentialKind (parsed (templateIn "personal" "u" (object [])))))
        assertBool "data at review" (isLeft (minioUserCredentialKind (parsed (template "u" (object ["data" .= object ["AWS_ACCESS_KEY_ID" .= ("eA==" :: Text)]])))))
        minioUserCredentialKind (object ["kind" .= ("Secret" :: Text), "metadata" .= object ["name" .= ("x" :: Text), "namespace" .= ("nagare-system" :: Text)]]) @?= Right Nothing
    , testCase "a user name may hold digits (EP-283)" $
        minioUserCredentialKind (parsed (template "nagare-bucket-0a1b2c3d4e5f" (object []))) @?= Right (Just "nagare-bucket-0a1b2c3d4e5f")
    , testCase "a workload's copy receives exactly the user's own credential (EP-283)" $ do
        let user = "nagare-bucket-0a1b2c3d4e5f"
            copy = copyIn "personal" user "kubernetes:source"
        generatedCredentialTemplate copy @?= Right True
        minioUserCopyKind (parsed copy) @?= Right (Just user)
        filledSource <- materializeCredential (template user (object [])) >>= either (assertFailure . T.unpack) pure
        let stamped ctx resource = stamp ctx resource (parsed filledSource)
            fill source = materializeMinioUserCopyWith (\asked -> pure (Right (ExitSuccess, T.unpack (TE.decodeUtf8 (either (error . T.unpack) id (canonicalValue (source asked)))), ""))) config copy
        filled <- fill (\asked -> if asked == user then stamped "bucket-fixture" "kubernetes:source" else Null) >>= either (assertFailure . T.unpack) pure
        value <- maybe (assertFailure "the copy was not filled" >> pure Null) (either (assertFailure . ("filled copy: " <>)) pure . eitherDecodeStrict . TE.encodeUtf8) filled
        dataOf value @?= dataOf (parsed filledSource)
        assertBool "the copy holds a key" (isJust (dataOf value))
        credentialDataMatches (parsed copy) value @?= True
        credentialDataMatches (parsed copy) (parsed copy) @?= False
        refusedOther <- fill (const (stamped "another-context" "kubernetes:source"))
        refusedOther @?= Left "object-store user credential is not the member this copy names"
        refusedMember <- fill (const (stamped "bucket-fixture" "kubernetes:another"))
        refusedMember @?= Left "object-store user credential is not the member this copy names"
        refusedEmpty <- fill (const (stamp "bucket-fixture" "kubernetes:source" (parsed (template user (object [])))))
        refusedEmpty @?= Left "object-store user credential lacks required data"
        unread <- materializeMinioUserCopyWith (\_ -> pure (Left "a template that is not a copy must not read Kubernetes")) config (template user (object []))
        unread @?= Right Nothing
    , testCase "a copy in nagare-system, with data, or naming no source is refused (EP-283)" $ do
        assertBool "nagare-system" (isLeft (minioUserCopyKind (parsed (copyIn "nagare-system" "u" "kubernetes:source"))))
        assertBool "no source" (isLeft (minioUserCopyKind (parsed (copyIn "personal" "u" ""))))
        assertBool "data at review" (isLeft (minioUserCopyKind (withData (parsed (copyIn "personal" "u" "kubernetes:source")))))
    ]
  where
    text = \case
      String t -> Just t
      _ -> Nothing
    parsed native = either (error . show) id (eitherDecodeStrict (TE.encodeUtf8 native))
    template :: Text -> Value -> Text
    template = templateIn "nagare-system"
    config = KubernetesRuntimeConfig (either (error . show) id (mkContextId "bucket-fixture")) "unused" (pure (Right ()))
    dataOf = \case
      Object root -> KM.lookup "data" root
      _ -> Nothing
    withData = \case
      Object root -> Object (KM.insert "data" (object ["AWS_ACCESS_KEY_ID" .= ("eA==" :: Text)]) root)
      other -> other
    stamp :: Text -> Text -> Value -> Value
    stamp ctx resource = \case
      Object root
        | Just (Object metadata) <- KM.lookup "metadata" root
        , Just (Object annotations) <- KM.lookup "annotations" metadata ->
            Object (KM.insert "metadata" (Object (KM.insert "annotations" (Object (KM.insert "nagare.dev/context-id" (String ctx) (KM.insert "nagare.dev/resource-id" (String resource) annotations))) metadata)) root)
      other -> other
    copyIn :: Text -> Text -> Text -> Text
    copyIn namespace user source =
      TE.decodeUtf8 . either (error . T.unpack) id . canonicalValue $
        object
          [ "apiVersion" .= ("v1" :: Text)
          , "kind" .= ("Secret" :: Text)
          , "metadata"
              .= object
                [ "name" .= ("nagare-bucket-publications-content-app" :: Text)
                , "namespace" .= namespace
                , "annotations" .= object ["nagare.dev/minio-user-copy" .= ("v1" :: Text), "nagare.dev/minio-user" .= user, "nagare.dev/minio-source-resource-id" .= source]
                ]
          ]
    templateIn :: Text -> Text -> Value -> Text
    templateIn namespace user (Object extra) =
      TE.decodeUtf8 . either (error . T.unpack) id . canonicalValue . Object $
        KM.union
          extra
          ( KM.fromList
              [ ("apiVersion", String "v1")
              , ("kind", String "Secret")
              , ("metadata", object ["name" .= user, "namespace" .= namespace, "annotations" .= object ["nagare.dev/minio-user-template" .= ("v1" :: Text), "nagare.dev/minio-user" .= user]])
              ]
          )
    templateIn _ _ _ = error "not an object"
