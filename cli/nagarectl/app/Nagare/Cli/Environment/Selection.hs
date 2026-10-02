-- | Environment / Selection. Executable-private CLI boundary.
module Nagare.Cli.Environment.Selection
  ( reconcileModeFrom
  , selectedScopes
  )
where

import Nagare.Cli.Options (ScopeSelection (..))
import Nagare.Dsl.Prelude
import Nagare.Dsl.Types (EnvScope (..))
import Nagare.Env.Store (ReconcileMode (..))

-- | Resolve the selected scopes; with none chosen, default to @[Runtime]@.
selectedScopes :: ScopeSelection -> [EnvScope]
selectedScopes (ScopeSelection r b p)
  | not r && not b && not p = [Runtime]
  | otherwise = [Runtime | r] <> [Build | b] <> [Preview | p]

-- | The reconcile mode for a sync.
reconcileModeFrom :: Bool -> ReconcileMode
reconcileModeFrom True = ReconcileExact
reconcileModeFrom False = Merge
