-- | A tunnel context's Cloudflare members against an in-memory provider, through the real
-- runtime's requests, before any live call (ADR 25).
module InventoryCloudflareZoneSpec (inventoryCloudflareZoneTests) where

import Data.Aeson (Value (..), decodeStrict, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Nagare.Dsl.Prelude hiding ((.=))
import Nagare.Inventory.Adapter
import Nagare.Inventory.Adapters.Cloudflare
import Nagare.Inventory.Adapters.CloudflareRuntime
import Nagare.Inventory.Components.CloudflareZone
import Nagare.Inventory.Digest (contentDigest)
import Nagare.Inventory.Journal (mkOperationId)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy
import Nagare.Resource.Types
import Nagare.Resource.Wire (decodeScope, encodeCanonicalScope)
import Test.Tasty
import Test.Tasty.HUnit

inventoryCloudflareZoneTests :: TestTree
inventoryCloudflareZoneTests =
  testGroup
    "Cloudflare zone scope"
    [ testCase "the scope declares one tunnel, its rules, two records, the edge policy and a bypass, and survives the wire" $ do
        decodeScope (encodeCanonicalScope fixtureScope) @?= Right fixtureScope
        length members @?= 5 + length tunnelEdgePolicy
        lookup "ssl" tunnelEdgePolicy @?= Just "strict"
        lookup "min_tls_version" tunnelEdgePolicy @?= Just "1.2"
        lookup "always_use_https" tunnelEdgePolicy @?= Just "on"
        lookup "rocket_loader" tunnelEdgePolicy @?= Just "off"
        lookup "email_obfuscation" tunnelEdgePolicy @?= Just "off"
    , testCase "every member binds to the adapter and is planned then written in order" $ do
        world <- newWorld
        let adapter = adapterFor world Map.empty
        mapM_ (runCreate adapter) ordered
        state <- readIORef world
        Map.size (tunnels state) @?= 1
        Map.keys (records state) @?= ["*." <> base, base]
        fmap recordContent (Map.lookup base (records state)) @?= Just (fakeTunnelId <> ".cfargotunnel.com")
        ingressHosts state @?= Just [Just base, Just ("*." <> base), Nothing]
        Map.lookup "ssl" (settings state) @?= Just "strict"
        Map.lookup "always_use_https" (settings state) @?= Just "on"
        rules state @?= Just "true"
    , testCase "a second pass over accepted members finds nothing to change" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) ordered
        before <- writeCount world
        let accepted = adapterFor world (Map.fromList [(member ^. #identity, member) | member <- ordered])
        facts <- adapterObserve accepted (map identityOf ordered) >>= either (fail . T.unpack) pure
        assertBool "every member is present" (all isPresent (Map.elems (observationMap facts)))
        after <- writeCount world
        after @?= before
    , testCase "a lost acknowledgement on the tunnel is resolved by observation and never creates a second one" $ do
        world <- newWorld
        modifyIORef' world (\state -> state {dropNextAcknowledgement = True})
        let adapter = adapterFor world Map.empty
            op = createOp tunnelMember
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        result <- adapterExecute adapter op prepared
        assertAmbiguous result
        verified <- adapterVerify adapter op prepared
        assertBool "the landed tunnel verifies" (isRightValue verified)
        state <- readIORef world
        Map.size (tunnels state) @?= 1
        -- A reviewed retry finds it present and refuses to create again.
        refused <- adapterPrepare adapter op
        assertBool "a create over an existing tunnel refuses" (isLeftValue refused)
    , testCase "a lost acknowledgement on the rules and on a record stays unresolved until observed" $ do
        world <- newWorld
        let setup = adapterFor world Map.empty
        runCreate setup tunnelMember
        modifyIORef' world (\state -> state {dropNextAcknowledgement = True})
        let op = createOp configMember
        prepared <- adapterPrepare setup op >>= either (fail . show) pure
        adapterExecute setup op prepared >>= assertAmbiguous
        adapterVerify setup op prepared >>= assertBool "landed rules verify" . isRightValue
        modifyIORef' world (\state -> state {dropNextAcknowledgement = True})
        let recordOp = createOp apexMember
        recordPrepared <- adapterPrepare setup recordOp >>= either (fail . show) pure
        adapterExecute setup recordOp recordPrepared >>= assertAmbiguous
        adapterVerify setup recordOp recordPrepared >>= assertBool "the landed record verifies" . isRightValue
    , testCase "rules repointed from Cloudflare read as drift and are not overwritten by observing them" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) ordered
        modifyIORef' world (\state -> state {ingress = Just [object ["hostname" .= ("evil." <> base), "service" .= ("http://169.254.169.254" :: Text)], object ["service" .= ("http_status:404" :: Text)]]})
        let accepted = adapterFor world (Map.fromList [(member ^. #identity, member) | member <- ordered])
        facts <- adapterObserve accepted [configMember ^. #identity] >>= either (fail . T.unpack) pure
        assertBool "repointed rules are drift" (all isDrifted (Map.elems (observationMap facts)))
        (fmap length . ingress <$> readIORef world) >>= (@?= Just 2)
    , testCase "a record pointing elsewhere or unproxied is drift, never accepted" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) ordered
        let accepted = adapterFor world (Map.fromList [(member ^. #identity, member) | member <- ordered])
            observe = adapterObserve accepted [apexMember ^. #identity] >>= either (fail . T.unpack) pure
        modifyIORef' world (\state -> state {records = Map.adjust (\r -> r {recordContent = "attacker.example"}) base (records state)})
        foreign' <- observe
        assertBool "a foreign target is drift" (all isDrifted (Map.elems (observationMap foreign')))
        modifyIORef' world (\state -> state {records = Map.adjust (\r -> r {recordContent = fakeTunnelId <> ".cfargotunnel.com", recordProxied = False}) base (records state)})
        unproxied <- observe
        assertBool "an unproxied record is drift" (all isDrifted (Map.elems (observationMap unproxied)))
    , testCase "an edge setting drifting back to a default is drift" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) ordered
        modifyIORef' world (\state -> state {settings = Map.insert "min_tls_version" "1.0" (settings state)})
        let accepted = adapterFor world (Map.fromList [(member ^. #identity, member) | member <- ordered])
            setting = settingMember "min_tls_version"
        facts <- adapterObserve accepted [setting ^. #identity] >>= either (fail . T.unpack) pure
        assertBool "a weakened minimum is drift" (all isDrifted (Map.elems (observationMap facts)))
    , testCase "a reviewed update restores a drifted setting that reports no modified time" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) ordered
        modifyIORef' world (\state -> state {settings = Map.insert "min_tls_version" "1.0" (settings state)})
        let setting = settingMember "min_tls_version"
            weakened = setting & #spec .~ CloudflareZoneSettingSpec "1.0"
            adapter = adapterFor world (Map.singleton (setting ^. #identity) weakened)
            op = (createOp setting) {plannedAction = UpdateResource}
        prepared <- adapterPrepare adapter op >>= either (fail . show) pure
        adapterExecute adapter op prepared >>= (@?= AdapterEffectCompleted)
        (Map.lookup "min_tls_version" . settings <$> readIORef world) >>= (@?= Just "1.2")
    , testCase "a zone setting's first write is allowed although the setting already has a value" $ do
        world <- newWorld
        let adapter = adapterFor world Map.empty
            setting = settingMember "ssl"
        facts <- adapterObserve adapter [setting ^. #identity] >>= either (fail . T.unpack) pure
        assertBool "an unclaimed setting is not unowned" (all isAbsent (Map.elems (observationMap facts)))
        runCreate adapter setting
        state <- readIORef world
        Map.lookup "ssl" (settings state) @?= Just "strict"
    , testCase "a base domain that is not the zone refuses, and no record is written" $ do
        world <- newWorld
        modifyIORef' world (\state -> state {zoneName = "other.example"})
        let adapter = adapterFor world Map.empty
        refused <- adapterPrepare adapter (createOp apexMember)
        assertBool "the record refuses" (isLeftValue refused)
        (Map.size . records <$> readIORef world) >>= (@?= 0)
    , testCase "an existing tunnel of the same name without history refuses instead of being taken over" $ do
        world <- newWorld
        mapM_ (runCreate (adapterFor world Map.empty)) [tunnelMember]
        facts <- adapterObserve (adapterFor world Map.empty) [tunnelMember ^. #identity] >>= either (fail . T.unpack) pure
        assertBool "a foreign tunnel is unowned" (all isUnowned (Map.elems (observationMap facts)))
    ]

base :: Text
base = "example.test"

fakeTunnelId :: Text
fakeTunnelId = "b855f1f5-a95c-4af1-af30-f707e1d3d6cd"

fixtureZone :: Name
fixtureZone = ok (mkName "zone1")

fixtureScope :: ScopeDeclaration
fixtureScope = either (error . show) id (compileCloudflareZone (CloudflareZoneInput fixtureZone base "ctx"))

members :: [ManagedResource]
members = [resource | bundle <- scopeBundles fixtureScope, Managed resource <- bundle ^. #declarations]

memberAt :: (ProviderAddress -> Bool) -> ManagedResource
memberAt wanted = case filter (wanted . (^. #address)) members of
  [one] -> one
  _ -> error "expected one member"

tunnelMember, configMember, apexMember, wildcardMember, bypassMember :: ManagedResource
tunnelMember = memberAt (\case CloudflareTunnel {} -> True; _ -> False)
configMember = memberAt (\case CloudflareTunnelConfig {} -> True; _ -> False)
apexMember = memberAt (\case CloudflareTunnelRecord _ role -> nameText role == "apex"; _ -> False)
wildcardMember = memberAt (\case CloudflareTunnelRecord _ role -> nameText role == "wildcard"; _ -> False)
bypassMember = memberAt (\case CloudflareRuleset {} -> True; _ -> False)

settingMember :: Text -> ManagedResource
settingMember setting = memberAt (\case CloudflareZoneSetting _ name -> nameText name == setting; _ -> False)

ordered :: [ManagedResource]
ordered = [tunnelMember, configMember, apexMember, wildcardMember, bypassMember] <> [settingMember name | (name, _) <- tunnelEdgePolicy]

identityOf :: ManagedResource -> ResourceId
identityOf = (^. #identity)

ok :: Either Text a -> a
ok = either (error . T.unpack) id

createOp :: ManagedResource -> PlannedOperation
createOp member =
  PlannedOperation
    (ok (mkOperationId ("op-" <> T.take 40 (T.filter (`notElem` (":/" :: String)) (resourceIdText (member ^. #identity))))))
    CreateResource
    CdnExecutor
    (member ^. #identity :| [])
    (contentDigest "cloudflare-zone-review")
    []
    VerifyBeforeRetry

runCreate :: Adapter -> ManagedResource -> IO ()
runCreate adapter member = do
  let op = createOp member
  prepared <- adapterPrepare adapter op >>= either (fail . show) pure
  adapterPreflight adapter op prepared >>= (@?= Right ())
  adapterExecute adapter op prepared >>= (@?= AdapterEffectCompleted)
  verified <- adapterVerify adapter op prepared
  assertBool ("not verified: " <> T.unpack (resourceIdText (member ^. #identity))) (isRightValue verified)

isRightValue :: Either a b -> Bool
isRightValue = either (const False) (const True)

isLeftValue :: Either a b -> Bool
isLeftValue = not . isRightValue

assertAmbiguous :: AdapterExecution -> Assertion
assertAmbiguous (AdapterEffectAmbiguous _) = pure ()
assertAmbiguous other = assertFailure ("expected an ambiguous outcome, got " <> show other)

isPresent, isDrifted, isAbsent, isUnowned :: ResourceObservation -> Bool
isPresent = \case ObservedPresent _ -> True; _ -> False
isDrifted = \case ObservedDrifted {} -> True; _ -> False
isAbsent = \case ConfirmedAbsent _ -> True; _ -> False
isUnowned = \case ObservedUnowned _ -> True; _ -> False

data FakeRecord = FakeRecord {recordId :: !Text, recordContent :: !Text, recordProxied :: !Bool}

data World = World
  { tunnels :: !(Map.Map Text Text)
  , ingress :: !(Maybe [Value])
  , records :: !(Map.Map Text FakeRecord)
  , settings :: !(Map.Map Text Text)
  , rulesBody :: !(Maybe Value)
  , zoneName :: !Text
  , writes :: !Int
  , dropNextAcknowledgement :: !Bool
  }

newWorld :: IO (IORef World)
newWorld =
  newIORef
    World
      { tunnels = Map.empty
      , ingress = Nothing
      , records = Map.empty
      , settings = Map.fromList [("ssl", "full"), ("min_tls_version", "1.0"), ("always_use_https", "off"), ("email_obfuscation", "on"), ("rocket_loader", "on"), ("server_side_exclude", "on"), ("automatic_https_rewrites", "on")]
      , rulesBody = Nothing
      , zoneName = base
      , writes = 0
      , dropNextAcknowledgement = False
      }

writeCount :: IORef World -> IO Int
writeCount world = writes <$> readIORef world

ingressHosts :: World -> Maybe [Maybe Text]
ingressHosts state = map hostOf <$> ingress state
  where
    hostOf (Object fields) = case KM.lookup "hostname" fields of
      Just (String host) -> Just host
      _ -> Nothing
    hostOf _ = Nothing

rules :: World -> Maybe Text
rules state = case rulesBody state of
  Just (Object body)
    | Just (Array values) <- KM.lookup "rules" body
    , [Object rule] <- toList values
    , Just (String expression) <- KM.lookup "expression" rule ->
        Just expression
  _ -> Nothing

adapterFor :: IORef World -> Map.Map ResourceId ManagedResource -> Adapter
adapterFor world accepted =
  mkCloudflareAdapter
    accepted
    specs
    ( cloudflareRuntimeOps
        CloudflareRuntimeConfig
          { cloudflareRuntimeZone = fixtureZone
          , cloudflareRuntimeAccount = "acct"
          , cloudflareRuntimeGuard = \_ -> pure (Right ())
          , cloudflareRuntimeSpecs = specs
          , cloudflareRuntimeRequest = fakeCloudflare world
          }
    )
  where
    specs = either (error . T.unpack) id (cloudflareBindingsFromDeclarations (map Managed members))

success :: Value -> IO (Either Text CloudflareResponse)
success result = pure (Right (200, LBS.toStrict (encode (object ["success" .= True, "result" .= result]))))

notFound :: IO (Either Text CloudflareResponse)
notFound =
  pure
    ( Right
        ( 404
        , LBS.toStrict
            ( encode
                ( object
                    [ "result" .= Null
                    , "success" .= False
                    , "errors" .= [object ["code" .= (10003 :: Int), "message" .= ("could not find entrypoint ruleset in the http_request_cache_settings phase" :: Text)]]
                    ]
                )
            )
        )
    )

-- | Just enough of Cloudflare's API for the runtime's requests. A dropped acknowledgement applies the
-- write and then fails the transport, which is the state a reviewed recovery must prove.
fakeCloudflare :: IORef World -> Text -> Text -> Maybe Value -> IO (Either Text CloudflareResponse)
fakeCloudflare world method path body = do
  state <- readIORef world
  case (method, path) of
    ("GET", "/zones/zone1") -> success (object ["id" .= ("zone1" :: Text), "name" .= zoneName state, "account" .= object ["id" .= ("acct" :: Text)]])
    ("GET", p)
      | "/accounts/acct/cfd_tunnel?" `T.isPrefixOf` p ->
          success (toJSONList [object ["id" .= tunnelId, "name" .= name, "created_at" .= ("2026-11-02T00:00:00Z" :: Text)] | (name, tunnelId) <- Map.toList (tunnels state)])
      | p == configPath ->
          success (object ["version" .= (1 :: Int), "config" .= maybe Null (\items -> object ["ingress" .= items]) (ingress state)])
      | Just encoded <- T.stripPrefix "/zones/zone1/dns_records?type=CNAME&name.exact=" p ->
          let name = T.replace "%2A" "*" encoded
           in success (toJSONList [recordJson name record | Just record <- [Map.lookup name (records state)]])
      | p == "/zones/zone1/rulesets/phases/http_request_cache_settings/entrypoint" -> case rulesBody state of
          Nothing -> notFound
          Just (Object fields) -> success (Object (KM.mapWithKey (\key value -> if key == "rules" then withProviderFields value else value) fields <> KM.fromList [("id", String "rs1"), ("version", String "1"), ("phase", String "http_request_cache_settings"), ("kind", String "zone")]))
          Just other -> success other
      | Just setting <- T.stripPrefix "/zones/zone1/settings/" p ->
          -- As observed: modified_on can be null or absent.
          success (object ["id" .= setting, "value" .= Map.findWithDefault "" setting (settings state), "modified_on" .= Null, "editable" .= True])
    ("POST", "/accounts/acct/cfd_tunnel") -> do
      let name = stringAt "name"
      mutate (\s -> s {tunnels = Map.insert name fakeTunnelId (tunnels s)}) (object ["id" .= fakeTunnelId])
    ("PUT", p)
      | p == configPath -> do
          let items = case body of
                Just (Object fields)
                  | Just (Object config) <- KM.lookup "config" fields
                  , Just (Array values) <- KM.lookup "ingress" config ->
                      Just (toList values)
                _ -> Nothing
          mutate (\s -> s {ingress = items}) (object [])
      | p == "/zones/zone1/rulesets/phases/http_request_cache_settings/entrypoint" ->
          mutate (\s -> s {rulesBody = body}) (object ["id" .= ("rs1" :: Text)])
    ("POST", "/zones/zone1/dns_records") ->
      mutate
        (\s -> s {records = Map.insert (stringAt "name") (FakeRecord ("r" <> T.pack (show (Map.size (records s)))) (stringAt "content") True) (records s)})
        (object [])
    ("PATCH", p)
      | Just setting <- T.stripPrefix "/zones/zone1/settings/" p ->
          mutate (\s -> s {settings = Map.insert setting (stringAt "value") (settings s)}) (object [])
    _ -> pure (Left ("the fake has no " <> method <> " " <> path))
  where
    configPath = "/accounts/acct/cfd_tunnel/" <> fakeTunnelId <> "/configurations"
    stringAt key = case body of
      Just (Object fields) | Just (String value) <- KM.lookup (Key.fromText key) fields -> value
      _ -> error ("the request has no " <> T.unpack key)
    recordJson name record =
      object
        [ "id" .= recordId record
        , "name" .= name
        , "content" .= recordContent record
        , "proxied" .= recordProxied record
        , "modified_on" .= ("2026-11-02T00:00:00Z" :: Text)
        ]
    mutate change result = do
      modifyIORef' world (\s -> (change s) {writes = writes s + 1})
      dropped <- dropNextAcknowledgement <$> readIORef world
      if dropped
        then do
          modifyIORef' world (\s -> s {dropNextAcknowledgement = False})
          pure (Left "connection reset after the write")
        else success result

toJSONList :: [Value] -> Value
toJSONList = Array . foldMap pure

-- | Cloudflare adds these to every stored rule (observed 2026-11-03).
withProviderFields :: Value -> Value
withProviderFields (Array rules) = Array (fmap added rules)
  where
    added (Object rule) = Object (rule <> KM.fromList [("id", String "rule1"), ("ref", String "rule1"), ("version", String "1"), ("last_updated", String "2026-11-03T00:00:00Z")])
    added other = other
withProviderFields other = other
