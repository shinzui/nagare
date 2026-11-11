-- | A delegated deployer's identity on a local context's in-cluster object
-- store (EP-248 D10). The MinIO user and its policy are reviewed members of
-- the delegation scope, written by one-shot Jobs with the store's client
-- image: a grant Job while the delegation is active, and a revoke Job, added
-- beside it on revocation, that removes the user with every key it holds.
-- Keys are MinIO service accounts of that user, issued and retired outside
-- any review by @deployer credentials@, so no review ever carries one.
--
-- The policy allows reading, conditionally writing and deleting objects
-- beneath the context's inventory prefix and listing only that prefix:
-- nothing in other prefixes, no bucket administration, no backups.
module Nagare.Inventory.DeployerStoreAccess
  ( StoreAccess (..)
  , storeUser
  , storePolicy
  , storeObjects
  , addKeyScript
  , retireKeysScript
  , keyPodOverrides
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Generics.Labels ()
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Access.Resolve (backendConfigMapNamespace)
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.DeployerAccess (IdentityObject (..))
import Nagare.Resource.Wire (canonicalValue)

-- | Where the context's inventory lives, and the client image that
-- administers the store.
data StoreAccess = StoreAccess
  { endpoint :: !Text
  -- ^ The in-cluster base URL, such as
  -- @http://minio.nagare-system.svc.cluster.local:9000@.
  , bucket :: !Text
  , prefix :: !Text
  , clientImage :: !Text
  }
  deriving stock (Eq, Show, Generic)

storeUser :: Text -> Text
storeUser deployer = "nagare-deployer-" <> deployer

-- | The canonical policy document.
storePolicy :: StoreAccess -> Either Text Text
storePolicy access =
  TE.decodeUtf8
    <$> canonicalValue
      ( object
          [ "Version" .= ("2012-10-17" :: Text)
          , "Statement"
              .= [ object
                     [ "Effect" .= ("Allow" :: Text)
                     , "Action" .= (["s3:DeleteObject", "s3:GetObject", "s3:PutObject"] :: [Text])
                     , "Resource" .= ["arn:aws:s3:::" <> access ^. #bucket <> "/" <> access ^. #prefix <> "/*"]
                     ]
                 , object
                     [ "Effect" .= ("Allow" :: Text)
                     , "Action" .= (["s3:ListBucket"] :: [Text])
                     , "Resource" .= ["arn:aws:s3:::" <> access ^. #bucket]
                     , "Condition" .= object ["StringLike" .= object ["s3:prefix" .= [access ^. #prefix <> "/*"]]]
                     ]
                 ]
          ]
      )

-- | The policy ConfigMap and the grant Job, plus the revoke Job when the
-- delegation is revoked. Jobs never change once created: the grant Job of
-- a revoked delegation stays as it ran.
storeObjects :: Text -> Bool -> StoreAccess -> Either Text [IdentityObject]
storeObjects deployer active access = do
  when (T.length (resourceName "-store-revoke") > 63) (Left "the deployer name is too long for its object store Jobs")
  policy <- storePolicy access
  pure
    ( [ IdentityObject "store-policy" (Just system) (policyMap policy) []
      , IdentityObject "store-grant" (Just system) (job "-store-grant" grantScript) ["store-policy"]
      ]
        <> [IdentityObject "store-revoke" (Just system) (job "-store-revoke" revokeScript) ["store-grant"] | not active]
    )
  where
    system = backendConfigMapNamespace
    user = storeUser deployer
    resourceName suffix = user <> suffix
    labels = object ["app.kubernetes.io/part-of" .= ("nagare" :: Text), "nagare.dev/delegation" .= deployer]
    policyMap policy =
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("ConfigMap" :: Text)
        , "metadata" .= object ["name" .= resourceName "-store", "namespace" .= system, "labels" .= labels]
        , "data" .= object ["policy.json" .= policy]
        ]
    alias = "until mc alias set root " <> access ^. #endpoint <> " \"$AWS_ACCESS_KEY_ID\" \"$AWS_SECRET_ACCESS_KEY\" >/dev/null; do echo waiting for the object store; sleep 2; done"
    grantScript =
      T.intercalate
        "\n"
        [ "set -eu"
        , alias
        , "mc admin policy create root " <> user <> " /policy/policy.json"
        , "mc admin user info root " <> user <> " >/dev/null 2>&1 || mc admin user add root " <> user <> " \"$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \\n')\""
        , "mc admin policy attach root " <> user <> " --user " <> user <> " >/dev/null 2>&1 || mc admin user info root " <> user <> " | grep -q 'PolicyName: " <> user <> "'"
        , "echo granted " <> user
        ]
    revokeScript =
      T.intercalate
        "\n"
        [ "set -eu"
        , alias
        , "if mc admin user info root " <> user <> " >/dev/null 2>&1; then mc admin user remove root " <> user <> "; fi"
        , "if mc admin policy info root " <> user <> " >/dev/null 2>&1; then mc admin policy remove root " <> user <> "; fi"
        , "echo revoked " <> user
        ]
    job suffix script =
      object
        [ "apiVersion" .= ("batch/v1" :: Text)
        , "kind" .= ("Job" :: Text)
        , "metadata" .= object ["name" .= resourceName suffix, "namespace" .= system, "labels" .= labels]
        , "spec"
            .= object
              [ "backoffLimit" .= (6 :: Int)
              , "template"
                  .= object
                    [ "metadata" .= object ["labels" .= labels]
                    , "spec"
                        .= object
                          ( [ "restartPolicy" .= ("OnFailure" :: Text)
                            , "automountServiceAccountToken" .= False
                            , "securityContext" .= podSecurity
                            , "containers"
                                .= [ object
                                       [ "name" .= ("mc" :: Text)
                                       , "image" .= (access ^. #clientImage)
                                       , "command" .= (["/bin/sh", "-c", script] :: [Text])
                                       , "env" .= rootCredentials
                                       , "securityContext" .= containerSecurity
                                       , "volumeMounts"
                                           .= ( [object ["name" .= ("home" :: Text), "mountPath" .= ("/home/mc" :: Text)]]
                                                  <> [object ["name" .= ("policy" :: Text), "mountPath" .= ("/policy" :: Text), "readOnly" .= True] | suffix == "-store-grant"]
                                              )
                                       ]
                                   ]
                            , "volumes"
                                .= ( [object ["name" .= ("home" :: Text), "emptyDir" .= object []]]
                                       <> [object ["name" .= ("policy" :: Text), "configMap" .= object ["name" .= resourceName "-store"]] | suffix == "-store-grant"]
                                   )
                            ]
                          )
                    ]
              ]
        ]

-- | The store's administrator credentials and a writable client home.
rootCredentials :: [Value]
rootCredentials =
  [ object ["name" .= ("HOME" :: Text), "value" .= ("/home/mc" :: Text)]
  , object ["name" .= ("MC_CONFIG_DIR" :: Text), "value" .= ("/home/mc/.mc" :: Text)]
  , secretKey "AWS_ACCESS_KEY_ID"
  , secretKey "AWS_SECRET_ACCESS_KEY"
  ]
  where
    secretKey :: Text -> Value
    secretKey key = object ["name" .= key, "valueFrom" .= object ["secretKeyRef" .= object ["name" .= ("nagare-minio-credentials" :: Text), "key" .= key]]]

podSecurity :: Value
podSecurity = object ["runAsNonRoot" .= True, "runAsUser" .= (65532 :: Int), "runAsGroup" .= (65532 :: Int), "seccompProfile" .= object ["type" .= ("RuntimeDefault" :: Text)]]

containerSecurity :: Value
containerSecurity = object ["allowPrivilegeEscalation" .= False, "readOnlyRootFilesystem" .= True, "capabilities" .= object ["drop" .= (["ALL"] :: [Text])]]

-- | Add one key to the deployer's user, read from standard input as two
-- lines, then prove it lists the inventory prefix. The key never appears in
-- the Pod's specification or output.
addKeyScript :: Text -> StoreAccess -> Text
addKeyScript deployer access =
  T.intercalate
    "\n"
    [ "set -eu"
    , "read -r key; read -r secret"
    , "mc alias set root " <> access ^. #endpoint <> " \"$AWS_ACCESS_KEY_ID\" \"$AWS_SECRET_ACCESS_KEY\" >/dev/null"
    , "mc admin user svcacct add root " <> storeUser deployer <> " --access-key \"$key\" --secret-key \"$secret\" >/dev/null"
    , "mc alias set issued " <> access ^. #endpoint <> " \"$key\" \"$secret\" >/dev/null"
    , "mc ls issued/" <> access ^. #bucket <> "/" <> access ^. #prefix <> "/ >/dev/null"
    , "echo verified"
    ]

-- | Remove every key of the deployer's user except the one on standard
-- input, printing each removed key id on its own line.
retireKeysScript :: Text -> StoreAccess -> Text
retireKeysScript deployer access =
  T.intercalate
    "\n"
    [ "set -eu"
    , "read -r keep"
    , "mc alias set root " <> access ^. #endpoint <> " \"$AWS_ACCESS_KEY_ID\" \"$AWS_SECRET_ACCESS_KEY\" >/dev/null"
    , "for key in $(mc admin user svcacct ls root " <> storeUser deployer <> " --json | sed -n 's/.*\"accessKey\": *\"\\([^\"]*\\)\".*/\\1/p'); do"
    , "  if [ \"$key\" != \"$keep\" ]; then mc admin user svcacct rm root \"$key\" >/dev/null; echo \"retired $key\"; fi"
    , "done"
    , "echo done"
    ]

-- | The @kubectl run --overrides@ of a key Pod: the client image, the
-- administrator credentials by reference, standard input attached.
keyPodOverrides :: Text -> StoreAccess -> Text -> Value
keyPodOverrides podName access script =
  object
    [ "apiVersion" .= ("v1" :: Text)
    , "spec"
        .= object
          [ "automountServiceAccountToken" .= False
          , "securityContext" .= podSecurity
          , "restartPolicy" .= ("Never" :: Text)
          , "containers"
              .= [ object
                     [ "name" .= podName
                     , "image" .= (access ^. #clientImage)
                     , "command" .= (["/bin/sh", "-c", script] :: [Text])
                     , "stdin" .= True
                     , "stdinOnce" .= True
                     , "env" .= rootCredentials
                     , "securityContext" .= containerSecurity
                     , "volumeMounts" .= [object ["name" .= ("home" :: Text), "mountPath" .= ("/home/mc" :: Text)]]
                     ]
                 ]
          , "volumes" .= [object ["name" .= ("home" :: Text), "emptyDir" .= object []]]
          ]
    ]
