-- | F87: an application drops one of its databases through review. Every
-- member of an application database carries the database's name as its
-- logical key. Naming the database selects exactly the accepted members the
-- new config no longer declares; the review retains each one (deleting
-- nothing) and frees the binding.
module Nagare.Inventory.Application.Retire (applicationDatabaseRetirements, contentRouteRetirements) where

import Data.List (nub)
import Data.Text qualified as T
import Nagare.Dsl.Prelude
import Nagare.Resource.Types (ResourceId, resourceIdText)

-- | The accepted application members to retain for each named database.
applicationDatabaseRetirements :: [ResourceId] -> [ResourceId] -> [Text] -> Either Text [ResourceId]
applicationDatabaseRetirements accepted desired names
  | nub names /= names = Left "each --retire-database name must be given once"
  | otherwise = concat <$> traverse retire names
  where
    retire name = do
      let members = [resource | resource <- accepted, keyOf resource == Just name]
      when (null members) (Left ("the application has no accepted database " <> name))
      when
        (any ((== Just name) . keyOf) desired)
        (Left ("database " <> name <> " is still declared; remove it from the config to retire it"))
      pure members
    keyOf resource = case T.splitOn "/" (resourceIdText resource) of
      [_, key, _] -> Just key
      _ -> Nothing

-- | EP-285: the accepted members of each named worker's content route that the
-- new config no longer declares: its Certificate and Ingress, and its Service
-- when the worker drops its port too. The review retains them; a later
-- @inventory collect@ deletes them.
contentRouteRetirements :: [ResourceId] -> [ResourceId] -> [Text] -> Either Text [ResourceId]
contentRouteRetirements accepted desired workers
  | nub workers /= workers = Left "each --retire-content-route worker must be given once"
  | otherwise = concat <$> traverse retire workers
  where
    retire worker = do
      let routeOf resource = keyOf resource == Just worker && roleOf resource `elem` map Just ["content-certificate", "content-ingress"]
          leaving = [resource | resource <- accepted, routeOf resource || (keyOf resource == Just worker && roleOf resource == Just "worker-service"), resource `notElem` desired]
      when (not (any routeOf accepted)) (Left ("the application has no accepted content route for worker " <> worker))
      when (any routeOf desired) (Left ("worker " <> worker <> " still declares a content route; remove it from the config to retire it"))
      pure leaving
    keyOf resource = case T.splitOn "/" (resourceIdText resource) of
      [_, key, _] -> Just key
      _ -> Nothing
    roleOf resource = case T.splitOn "/" (resourceIdText resource) of
      [_, _, role] -> Just role
      _ -> Nothing
