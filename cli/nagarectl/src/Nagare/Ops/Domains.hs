-- | The @nagarectl domains list@ inventory: extract Knative @DomainMapping@ and
-- cert-manager @Certificate@ state, compute each domain's DNS expectation, and
-- format the table (MasterPlan 8, EP-40).
--
-- Everything here is pure — the JSON extractors, the (computed, not resolved)
-- DNS expectation, the certificate grader, and the formatter — so the whole
-- inventory is unit-testable without a cluster. The thin @kubectl@ IO that
-- gathers the JSON and assembles the rows lives in @app/Main.hs@.
--
-- This is EP-40 of MasterPlan 8; it soft-reuses EP-38's
-- 'Nagare.Ops.Pulumi.stackOutput' for base-domain/publicIp resolution in the
-- command layer, but defines its own three-line JSON walkers here (mirroring how
-- "Nagare.App" keeps local copies) so the module is self-contained. The DNS
-- column is a computed expectation (wildcard membership + reserved IP), never a
-- live @dig@.
module Nagare.Ops.Domains
  ( DomainRow (..)
  , DnsExpectation (..)
  , CertState (..)
  , DomainMapping (..)
  , extractDomainMappings
  , extractCertReadiness
  , dnsExpectationFor
  , certStateFor
  , formatDomainList

    -- * Cluster queries (thin kubectl IO)
  , queryDomainRows
  , listNamespaces
  ) where

import Nagare.Dsl.Prelude

import Data.Aeson (eitherDecodeStrict)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.List (find)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Vector qualified as V

import Nagare.Ops.Probe (captureTool)

-- ---------------------------------------------------------------------------
-- Types

-- | One row of @domains list@: a domain, the Service it routes to, its
-- DomainMapping readiness, its DNS expectation, and its certificate state.
data DomainRow = DomainRow
  { drDomain :: !Text
  -- ^ the hostname (base apex, or DomainMapping host)
  , drService :: !(Maybe Text)
  -- ^ owning Service (@.spec.ref.name@); 'Nothing' for the base row
  , drMappingReady :: !(Maybe Bool)
  -- ^ DomainMapping @Ready@ condition; 'Nothing' for the base row
  , drDns :: !DnsExpectation
  , drCert :: !CertState
  }
  deriving stock (Generic, Eq, Show)

-- | What DNS /should/ look like for this domain (computed, not resolved).
data DnsExpectation
  = UnderWildcard !Text
  -- ^ falls under @*.\<baseDomain\>@; payload is the expected A target (publicIp)
  | OutsideWildcard
  -- ^ does NOT fall under @*.\<baseDomain\>@; needs its own record
  deriving stock (Generic, Eq, Show)

-- | Certificate readiness for a domain.
data CertState
  = CertReady
  -- ^ a Certificate covering this domain exists and is @Ready@
  | CertPending
  -- ^ a Certificate covers this domain but is not yet @Ready@
  | CertDisabled
  -- ^ no Certificate present / external-domain TLS off
  deriving stock (Generic, Eq, Show)

-- | A decoded @DomainMapping@: hostname, owning Service, and @Ready@ state.
data DomainMapping = DomainMapping
  { dmHost :: !Text
  , dmService :: !(Maybe Text)
  , dmReady :: !(Maybe Bool)
  }
  deriving stock (Generic, Eq, Show)

-- ---------------------------------------------------------------------------
-- JSON walk helpers (local copies, mirroring Nagare.App)

lookupPath :: [Text] -> Aeson.Value -> Maybe Aeson.Value
lookupPath [] v = Just v
lookupPath (k : ks) (Aeson.Object o) = KeyMap.lookup (Key.fromText k) o >>= lookupPath ks
lookupPath _ _ = Nothing

textAt :: [Text] -> Aeson.Value -> Maybe Text
textAt path v = case lookupPath path v of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

-- | The @Ready@ condition's truth from @.status.conditions[]@, or 'Nothing' when
-- no @Ready@ condition is present yet.
readyOf :: Aeson.Value -> Maybe Bool
readyOf v = do
  Aeson.Array conds <- lookupPath ["status", "conditions"] v
  cond <- find (\c -> textAt ["type"] c == Just "Ready") (V.toList conds)
  st <- textAt ["status"] cond
  pure (st == "True")

-- ---------------------------------------------------------------------------
-- Extractors

-- | Decode @kubectl get domainmapping -n \<ns\> -o json@ into
-- @(host, service, ready)@ triples. Defensive: malformed JSON is a 'Left',
-- an absent/empty @.items@ is @Right []@.
extractDomainMappings :: ByteString -> Either Text [DomainMapping]
extractDomainMappings bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode domainmapping list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) ->
        Right
          [ DomainMapping host (textAt ["spec", "ref", "name"] item) (readyOf item)
          | item <- V.toList items
          , Just host <- [textAt ["metadata", "name"] item]
          ]
      _ -> Right []

-- | Decode @kubectl get certificate -n \<ns\> -o json@ into per-DNS-name
-- readiness: each Certificate contributes @(dnsName, ready)@ for every name in
-- its @.spec.dnsNames@. Malformed JSON is a 'Left'; an absent/empty list (TLS
-- disabled, no CRD) is @Right []@ — the graceful TLS-disabled path.
extractCertReadiness :: ByteString -> Either Text [(Text, Bool)]
extractCertReadiness bs =
  case eitherDecodeStrict bs of
    Left e -> Left ("could not decode certificate list JSON: " <> T.pack e)
    Right v -> case lookupPath ["items"] v of
      Just (Aeson.Array items) ->
        Right
          [ (name, ready)
          | item <- V.toList items
          , let ready = readyOf item == Just True
          , Aeson.Array names <- [fromMaybe (Aeson.Array V.empty) (lookupPath ["spec", "dnsNames"] item)]
          , Aeson.String name <- V.toList names
          ]
      _ -> Right []

-- ---------------------------------------------------------------------------
-- DNS expectation and certificate grading

-- | Compute the DNS expectation for @domain@ given the base domain and the
-- reserved public IP. Pure; no resolver call. v1: wildcard membership only — the
-- apex and any single-label subdomain of the base are 'UnderWildcard'; anything
-- else is 'OutsideWildcard'.
dnsExpectationFor :: Text -> Text -> Text -> DnsExpectation
dnsExpectationFor baseDomain publicIp domain
  | domain == baseDomain = UnderWildcard publicIp
  | otherwise = case T.stripSuffix ("." <> baseDomain) domain of
      Just label | not (T.null label) && not ("." `T.isInfixOf` label) -> UnderWildcard publicIp
      _ -> OutsideWildcard

-- | Grade one domain's 'CertState' from the readiness map. A domain is covered
-- either by an exact cert name or by a wildcard cert name (@*.suffix@ matching a
-- single-label subdomain of @suffix@). No match is 'CertDisabled'.
certStateFor :: [(Text, Bool)] -> Text -> CertState
certStateFor readiness domain =
  case find (\(name, _) -> name `covers` domain) readiness of
    Nothing -> CertDisabled
    Just (_, ready) -> if ready then CertReady else CertPending
  where
    covers name d
      | name == d = True
      | Just suffix <- T.stripPrefix "*." name =
          case T.stripSuffix ("." <> suffix) d of
            Just label -> not (T.null label) && not ("." `T.isInfixOf` label)
            Nothing -> False
      | otherwise = False

-- ---------------------------------------------------------------------------
-- Formatter

-- | Render rows as an aligned @DOMAIN / SERVICE / DNS / CERT@ table. Pure. The
-- wildcard base used in the DNS cell is read from the base row (the row with no
-- owning Service).
formatDomainList :: [DomainRow] -> Text
formatDomainList [] = "(no domains)\n"
formatDomainList rows = T.unlines (header : map row rows)
  where
    base = maybe "" drDomain (find (isNothing . drService) rows)
    header = "  " <> pad 32 "DOMAIN" <> pad 16 "SERVICE" <> pad 34 "DNS" <> "CERT"
    row r =
      "  "
        <> pad 32 (drDomain r)
        <> pad 16 (fromMaybe "(base)" (drService r))
        <> pad 34 (dnsCell r)
        <> certCell (drCert r)
    dnsCell r = case drDns r of
      UnderWildcard ip -> "*." <> base <> " A -> " <> ip
      OutsideWildcard -> "(outside wildcard)"
    certCell CertReady = "Ready"
    certCell CertPending = "pending"
    certCell CertDisabled = "disabled"
    pad n t = let t' = T.take n t in t' <> T.replicate (max 1 (n - T.length t')) " "

-- ---------------------------------------------------------------------------
-- Cluster queries (thin kubectl IO; the pure extractors above do the parsing)

-- | Query one namespace's @DomainMapping@s and @Certificate@s and assemble the
-- rows. Read-only. A non-zero @kubectl@ exit (absent resource / missing
-- @Certificate@ CRD) degrades to empty bytes → no rows / 'CertDisabled', never a
-- crash — the graceful TLS-disabled path.
queryDomainRows :: Text -> Text -> Text -> IO [DomainRow]
queryDomainRows base ip ns = do
  dms <- kubeGetJson ["get", "domainmapping", "-n", T.unpack ns, "-o", "json"]
  certs <- kubeGetJson ["get", "certificate", "-n", T.unpack ns, "-o", "json"]
  let mappings = either (const []) id (extractDomainMappings dms)
      readiness = either (const []) id (extractCertReadiness certs)
  pure
    [ DomainRow
        (dmHost m)
        (dmService m)
        (dmReady m)
        (dnsExpectationFor base ip (dmHost m))
        (certStateFor readiness (dmHost m))
    | m <- mappings
    ]

-- | Capture @kubectl \<args\>@ stdout via EP-38's 'captureTool' (the IP4
-- wrapper), tolerating a non-zero exit /or a missing @kubectl@ binary/ by
-- returning empty bytes so the pure extractors yield @[]@.
kubeGetJson :: [String] -> IO ByteString
kubeGetJson args = fromMaybe "" <$> captureTool "kubectl" args

-- | List namespace names via @kubectl get ns -o name@ (the resource prefix
-- stripped). Empty when @kubectl@ is missing or the query fails.
listNamespaces :: IO [Text]
listNamespaces = do
  m <- captureTool "kubectl" ["get", "ns", "-o", "name"]
  pure $ case m of
    Nothing -> []
    Just bs -> [T.strip (snd (T.breakOnEnd "/" l)) | l <- T.lines (decodeUtf8 bs), not (T.null (T.strip l))]
