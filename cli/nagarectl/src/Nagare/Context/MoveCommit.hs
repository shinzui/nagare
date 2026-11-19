-- | What a move's commit, or the later retirement of the kept Cloud DNS set, reviews next (EP-243).
-- A set of cloud members leaves the accepted cloud scope the way cloud teardown removes one: a policy
-- review lets the collectable ones be deleted, a scope revision retires the whole set with its native
-- resources kept, and one exact collection deletes each collectable one. When none is left the caller
-- writes the profile: for the commit, the move's point of no return.
module Nagare.Context.MoveCommit
  ( CommitAction (..)
  , RetiredSet (..)
  , webRuleSet
  , cloudDnsSet
  , commitAction
  , stampWithout
  , retiredMember
  , isTunnelWebRule
  )
where

import Data.Generics.Labels ()
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Cloud (tunnelWebRuleKeys)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Reference (Dependency (..))
import Nagare.Resource.Types

data CommitAction
  = -- | Replace the cloud scope with this one, whose collectable members of the set may be deleted.
    CommitPolicy !ScopeDeclaration
  | -- | Replace the cloud scope with this one, without the set, retiring these members.
    CommitRetire !ScopeDeclaration ![ResourceId]
  | -- | Collect this retained member.
    CommitCollect !ResourceId
  | -- | Nothing is left to review: write the profile.
    CommitProfile
  deriving stock (Eq, Show)

-- | The members leaving the cloud scope, by Pulumi logical name, in collection order, and which of
-- them are deleted. The rest are authority (IAM) that cloud collection never deletes: they are
-- retired and stay in the project.
data RetiredSet = RetiredSet
  { keys :: ![Text]
  , collected :: ![Text]
  }
  deriving stock (Eq, Show, Generic)

webRuleSet :: RetiredSet
webRuleSet = RetiredSet tunnelWebRuleKeys tunnelWebRuleKeys

-- | The Cloud DNS set a moved context keeps (D2): records before their zone, and the solver's two
-- grants, which go with the zone's retirement but are not deleted by it.
cloudDnsSet :: RetiredSet
cloudDnsSet =
  RetiredSet
    ["nagare-wildcard", "nagare-apex", "nagare-zone", "nagare-iam-dns-zone", "nagare-iam-dns-read"]
    ["nagare-wildcard", "nagare-apex", "nagare-zone"]

-- | The next review, from the accepted cloud scope and the members of the set history still retains.
commitAction :: RetiredSet -> Maybe ScopeDeclaration -> [ManagedResource] -> Either Text CommitAction
commitAction retiring accepted retained = case accepted of
  Nothing -> Left "the context has no accepted platform cloud scope"
  Just scope
    | any ((/= DeleteWhenUnreferenced) . (^. #lifecycle)) (filter collectable members) -> CommitPolicy <$> revise scope policy
    | not (null members) -> (`CommitRetire` map (^. #identity) members) <$> revise scope (const Nothing)
    | resource : _ <- sortOn order (filter collectable retained) -> Right (CommitCollect (resource ^. #identity))
    | otherwise -> Right CommitProfile
    where
      members = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle, isJust (memberKey retiring member)]
  where
    collectable member = maybe False (`elem` retiring ^. #collected) (memberKey retiring member)
    order member = maybe maxBound (\key -> length (takeWhile (/= key) (retiring ^. #keys))) (memberKey retiring member)
    policy member
      | collectable member = Just (member & #lifecycle .~ DeleteWhenUnreferenced)
      | otherwise = Just member
    revise scope change = do
      updated <-
        first
          (T.pack . show)
          ( mkScopeDeclaration
              (scopeId scope)
              [ bundle {declarations = kept}
              | bundle <- scopeBundles scope
              , let kept = concatMap (edit change) (declarations bundle)
              , not (null kept)
              ]
          )
      pure (withScopeOverrides (scopeOverrides scope) (maybe updated (`withScopeConfigDigest` updated) (scopeConfigDigest scope)))
    edit change = \case
      Managed member | isJust (memberKey retiring member) -> maybe [] (pure . Managed) (change member)
      other -> [other]

-- | Whether a member, as history retains it, belongs to the set: a member of the cloud scope.
retiredMember :: RetiredSet -> ManagedResource -> Bool
retiredMember retiring member =
  scopeKind (member ^. #owner) == Platform
    && nameText (scopeName (member ^. #owner)) == "cloud"
    && isJust (memberKey retiring member)

-- | A member of the cloud scope that is one of the three web rules.
isTunnelWebRule :: ManagedResource -> Bool
isTunnelWebRule = isJust . memberKey webRuleSet

-- | The set's logical name a member's Pulumi URN ends with, if any.
memberKey :: RetiredSet -> ManagedResource -> Maybe Text
memberKey retiring member =
  listToMaybe
    [ key
    | PulumiUrn urn <- member ^. #address : member ^. #aliases
    , key <- retiring ^. #keys
    , ("::" <> key) `T.isSuffixOf` urn
    ]

-- | The bootstrap stamp without its ordering edges to the retiring members. The stamp orders after every
-- platform member, so a scope revision that retires some of them must drop those edges with it, or its
-- composition leaves them dangling. Only the edges change, so the stamp's object is not rewritten.
stampWithout :: [ResourceId] -> ScopeSnapshot -> Maybe ScopeChange
stampWithout retiring snapshot = do
  owner <- either (const Nothing) Just (mkScopeId Platform "bootstrap-stamp")
  (_, stamp) <- Map.lookup owner (snapshotScopes snapshot)
  let edgeKept = \case
        OrderedAfter target -> target `notElem` retiring
        _ -> True
      revise = \case
        Managed m -> Managed (m & #dependencies %~ filter edgeKept)
        other -> other
      bundles = [bundle & #declarations %~ map revise | bundle <- scopeBundles stamp]
  revised <- either (const Nothing) Just (withScopeOverrides (scopeOverrides stamp) . maybe id withScopeConfigDigest (scopeConfigDigest stamp) <$> mkScopeDeclaration owner bundles)
  if revised == stamp then Nothing else Just (ReplaceScope revised)
