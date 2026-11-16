-- | The decisions behind a move's observation and wait steps (EP-243), as pure functions over what
-- the CLI observed, so each one is tested without a network. The production interpreter gathers
-- the facts (@dig@, the Cloudflare API, cert-manager) and asks these what the step's outcome is.
module Nagare.Context.MoveChecks
  ( renewalMargin
  , ZoneStatus (..)
  , DnssecStatus (..)
  , DigRecord (..)
  , parseDigRecords
  , preconditions
  , nameServersActive
  , dnssecReady
  , dnssecRemoved
  , directAnswers
  , edgeAnswers
  , oldAnswersExpired
  , edgeCachesExpired
  , nameServersReturned
  , sameNameServers
  , reviewSettled
  )
where

import Data.Char (isDigit)
import Data.Generics.Labels ()
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, nominalDay)
import Data.Time.Format.ISO8601 (iso8601Show)
import Nagare.Context.Move (StepOutcome (..))
import Nagare.Dsl.Prelude
import Nagare.Inventory.Adapter (OperationAction (VerifyResource))
import Nagare.Inventory.Store.Manifest (ScopeRevision (revisionDigest))
import Nagare.Resource.Types (ScopeId)

-- | How long a move may hold Cloud DNS out of authority while origin certificates are still in use:
-- DNS-01 renewal needs Cloud DNS, so a move refuses to start when any certificate renews sooner. The
-- window closes at @close-kourier@, after which no origin certificate serves a visitor.
renewalMargin :: NominalDiffTime
renewalMargin = 14 * nominalDay

-- | What Cloudflare reports for the zone: @active@ once the registrar's name servers point at it.
data ZoneStatus = ZoneStatus
  { zoneName :: !Text
  , zoneState :: !Text
  , assignedNameServers :: ![Text]
  , activatedOn :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show, Generic)

-- | Cloudflare's DNSSEC state for the zone and the DS record the registrar must publish.
data DnssecStatus = DnssecStatus
  { dnssecState :: !Text
  , dsRecord :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | One record of @dig +noall +answer@ or @+authority@ output.
data DigRecord = DigRecord
  { owner :: !Text
  , ttl :: !Int
  , recordType :: !Text
  , value :: !Text
  }
  deriving stock (Eq, Show, Generic)

parseDigRecords :: Text -> [DigRecord]
parseDigRecords = mapMaybe record . T.lines
  where
    record line = case T.words line of
      name : ttlText : "IN" : kind : rest
        | not (T.isPrefixOf ";" name)
        , not (T.null ttlText)
        , T.all isDigit ttlText
        , not (null rest) ->
            Just (DigRecord (normalName name) (read (T.unpack ttlText)) kind (T.unwords rest))
      _ -> Nothing

-- | @check-preconditions@: the account holds the zone, the parent publishes no DS record (Cloud DNS's
-- keys would fail validation once Cloudflare answers), and no certificate renews inside the window.
preconditions :: UTCTime -> Text -> Maybe ZoneStatus -> Bool -> [(Text, Maybe UTCTime)] -> StepOutcome
preconditions now base zone parentDs renewals
  | Nothing <- zone =
      StepWaiting
        ( "add "
            <> base
            <> " to the Cloudflare account, and export CF_API_TOKEN, CF_ACCOUNT_ID and CF_ZONE_ID for it"
        )
  | Just status <- zone
  , normalName (status ^. #zoneName) /= normalName base =
      StepRefused ("CF_ZONE_ID names the zone " <> status ^. #zoneName <> ", not " <> base)
  | parentDs =
      StepRefused
        ( "the parent zone publishes a DS record for "
            <> base
            <> "; remove it at the registrar and wait for its TTL first, or validating resolvers fail once Cloudflare answers"
        )
  | (name, _) : _ <- [r | r@(_, Nothing) <- renewals] =
      StepRefused ("certificate " <> name <> " has no renewal time; wait until cert-manager reports it ready")
  | (name, Just renewsAt) : _ <- [r | r@(_, Just soon) <- renewals, soon < addUTCTime renewalMargin now] =
      StepRefused
        ( "certificate "
            <> name
            <> " renews at "
            <> stamp renewsAt
            <> ", inside the move's window; start the move after it has renewed"
        )
  | otherwise = StepCompleted

-- | @await-name-servers@: Cloudflare activates the zone once the registrar points at its name servers.
nameServersActive :: ZoneStatus -> StepOutcome
nameServersActive status
  | status ^. #zoneState == "active" = StepCompleted
  | otherwise =
      StepWaiting
        ( "set the name servers for "
            <> status ^. #zoneName
            <> " at the registrar to "
            <> T.intercalate " and " (status ^. #assignedNameServers)
            <> "; Cloudflare reports the zone "
            <> status ^. #zoneState
        )

-- | @enable-dnssec@: DNSSEC is on at Cloudflare and the registrar publishes its DS record.
dnssecReady :: DnssecStatus -> StepOutcome
dnssecReady status = case status ^. #dnssecState of
  "active" -> StepCompleted
  "pending" ->
    StepWaiting
      ( "publish this DS record at the registrar: "
          <> fromMaybe "(Cloudflare returned none yet; run again in a minute)" (status ^. #dsRecord)
      )
  other -> StepWaiting ("turn DNSSEC on for the zone in Cloudflare (DNS, Settings); it reports " <> other)

-- | Undoing @enable-dnssec@: the parent's DS record must go before the name servers move back.
dnssecRemoved :: Bool -> StepOutcome
dnssecRemoved parentDs
  | parentDs = StepWaiting "remove the DS record at the registrar; Cloud DNS cannot answer for Cloudflare's keys"
  | otherwise = StepCompleted

-- | @confirm-direct@, and the guard before records move back: the VM still serves.
directAnswers :: Text -> Bool -> StepOutcome
directAnswers base answered
  | answered = StepCompleted
  | otherwise = StepRefused (base <> " does not answer on the VM's address; direct ingress must work before records move")

-- | @verify-tunnel@: every sampled hostname answers through the edge. 'Nothing' means public DNS still
-- answers with the VM's address, a mirror answer not yet expired: wait for it.
edgeAnswers :: [(Text, Maybe Bool)] -> StepOutcome
edgeAnswers results
  | null results = StepRefused "no hostname was sampled through the edge"
  | direct@(_ : _) <- [host | (host, Nothing) <- results] =
      StepWaiting ("public DNS still sends " <> T.intercalate ", " direct <> " to the VM; run again in a few minutes")
  | silent@(_ : _) <- [host | (host, Just False) <- results] =
      StepRefused ("through the edge, these do not answer: " <> T.intercalate ", " silent)
  | otherwise = StepCompleted

-- | @await-old-ttl@, and the guard before the firewall closes: every answer that sends a visitor to
-- the VM has expired. A resolver may hold the old delegation for the parent's NS TTL after Cloudflare
-- activated and then a Cloud DNS answer for its record TTL; another may hold a mirror record for its
-- TTL after the switch.
oldAnswersExpired :: UTCTime -> Int -> Maybe UTCTime -> Int -> Maybe UTCTime -> StepOutcome
oldAnswersExpired now recordTtl activated parentNsTtl switched = case (activated, switched) of
  (Nothing, _) -> StepRefused "Cloudflare reports no activation time for the zone"
  (_, Nothing) -> StepRefused "the zone's apex record has no modification time"
  (Just activatedAt, Just switchedAt)
    | now >= expiry -> StepCompleted
    | otherwise -> StepWaiting ("a cached answer may still send a visitor to the VM until " <> stamp expiry)
    where
      expiry =
        max
          (addUTCTime (seconds (parentNsTtl + recordTtl)) activatedAt)
          (addUTCTime (seconds recordTtl) switchedAt)

-- | Undoing @carry-hostnames@ or @start-connector@: the records point at the VM again, and an edge
-- answer cached before that has expired.
edgeCachesExpired :: UTCTime -> Int -> Bool -> Maybe UTCTime -> StepOutcome
edgeCachesExpired now recordTtl recordsToVm switchedBack
  | not recordsToVm = StepWaiting "the zone's records still point at the tunnel"
  | Just back <- switchedBack
  , now < addUTCTime (seconds recordTtl) back =
      StepWaiting ("a cached edge answer may still use the tunnel until " <> stamp (addUTCTime (seconds recordTtl) back))
  | Nothing <- switchedBack = StepRefused "the zone's apex record has no modification time"
  | otherwise = StepCompleted

-- | Undoing @mirror-zone@: the parent delegates to Cloud DNS again, and every sampled resolver
-- already answers with Cloud DNS's name servers, so removing the mirror strands no visitor.
nameServersReturned :: [Text] -> [Text] -> [[Text]] -> StepOutcome
nameServersReturned cloudDns parent resolvers
  | not (sameNameServers cloudDns parent) =
      StepWaiting ("point the name servers back at Cloud DNS at the registrar: " <> T.intercalate " and " (map normalName cloudDns))
  | not (all (sameNameServers cloudDns) resolvers) = StepWaiting "public resolvers still answer with Cloudflare's name servers"
  | otherwise = StepCompleted

-- | A step's review changes nothing: it only verifies, and each scope it would write has the
-- accepted content. Composition bumps a selected scope's generation even when nothing in it changed,
-- so the digests decide, not the revisions.
reviewSettled :: [OperationAction] -> Map ScopeId ScopeRevision -> Map ScopeId ScopeRevision -> Bool
reviewSettled actions desired accepted =
  all (== VerifyResource) actions
    && and [fmap revisionDigest (Map.lookup scope accepted) == Just (revisionDigest revision) | (scope, revision) <- Map.toList desired]

sameNameServers :: [Text] -> [Text] -> Bool
sameNameServers a b = not (null a) && canonical a == canonical b
  where
    canonical = sort . nub . map normalName

normalName :: Text -> Text
normalName = T.toLower . T.dropWhileEnd (== '.') . T.strip

seconds :: Int -> NominalDiffTime
seconds = fromIntegral

stamp :: UTCTime -> Text
stamp = T.pack . iso8601Show
