-- | What @commit-move@ reviews next (EP-243). The three web firewall rules leave the accepted cloud
-- scope the way cloud teardown removes a member: a policy review lets them be deleted, a scope
-- revision retires them with their native rules kept, and one exact collection deletes each. When
-- none is left the commit writes the profile, which is the move's point of no return.
module Nagare.Context.MoveCommit
  ( CommitAction (..)
  , commitAction
  , isTunnelWebRule
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Inventory.Cloud (tunnelWebRuleKeys)
import Nagare.Resource.Inventory
import Nagare.Resource.Policy (LifecyclePolicy (DeleteWhenUnreferenced))
import Nagare.Resource.Types

data CommitAction
  = -- | Replace the cloud scope with this one, whose web rules may be deleted.
    CommitPolicy !ScopeDeclaration
  | -- | Replace the cloud scope with this one, without the web rules, retiring these members.
    CommitRetire !ScopeDeclaration ![ResourceId]
  | -- | Collect this retained web rule.
    CommitCollect !ResourceId
  | -- | Nothing is left to review: write the tunnel profile.
    CommitProfile
  deriving stock (Eq, Show)

-- | The next commit review, from the accepted cloud scope and the web rules history still retains.
commitAction :: Maybe ScopeDeclaration -> [ResourceId] -> Either Text CommitAction
commitAction accepted retained = case accepted of
  Nothing -> Left "the context has no accepted platform cloud scope"
  Just scope
    | any ((/= DeleteWhenUnreferenced) . (^. #lifecycle)) rules -> CommitPolicy <$> revise scope policy
    | not (null rules) -> (`CommitRetire` map (^. #identity) rules) <$> revise scope (const Nothing)
    | resource : _ <- retained -> Right (CommitCollect resource)
    | otherwise -> Right CommitProfile
    where
      rules = [member | bundle <- scopeBundles scope, Managed member <- declarations bundle, isTunnelWebRule member]
  where
    policy member = Just (member & #lifecycle .~ DeleteWhenUnreferenced)

-- | A member of the cloud scope that is one of the three web rules.
isTunnelWebRule :: ManagedResource -> Bool
isTunnelWebRule member =
  or
    [ ("::" <> key) `T.isSuffixOf` urn
    | PulumiUrn urn <- member ^. #address : member ^. #aliases
    , key <- tunnelWebRuleKeys
    ]

-- | The scope with each web rule replaced by @change@ (or dropped), every other member unchanged.
revise :: ScopeDeclaration -> (ManagedResource -> Maybe ManagedResource) -> Either Text ScopeDeclaration
revise scope change = do
  updated <-
    first
      (T.pack . show)
      ( mkScopeDeclaration
          (scopeId scope)
          [ bundle {declarations = kept}
          | bundle <- scopeBundles scope
          , let kept = concatMap edit (declarations bundle)
          , not (null kept)
          ]
      )
  pure (withScopeOverrides (scopeOverrides scope) (maybe updated (`withScopeConfigDigest` updated) (scopeConfigDigest scope)))
  where
    edit = \case
      Managed member | isTunnelWebRule member -> maybe [] (pure . Managed) (change member)
      other -> [other]
