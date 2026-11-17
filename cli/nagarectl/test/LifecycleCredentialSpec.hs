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
import Nagare.Inventory.Adapters.CredentialTemplate (credentialDataMatches, generatedCredentialTemplate, materializeCredential, minioUserCredentialKind)
import Nagare.Resource.Wire (canonicalValue)
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
    ]
  where
    text = \case
      String t -> Just t
      _ -> Nothing
    parsed native = either (error . show) id (eitherDecodeStrict (TE.encodeUtf8 native))
    template :: Text -> Value -> Text
    template = templateIn "nagare-system"
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
