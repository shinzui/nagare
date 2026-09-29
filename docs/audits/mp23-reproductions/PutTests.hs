{-# LANGUAGE OverloadedStrings #-}
import Nagare.Inventory.Store.ObjectOps
import Control.Monad (unless)
main = do
  let prefix = "gs://example-bucket/private/inventory"
      name = ObjectName "journal/00000000000000000001.json"
      cases = [ createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000001.json#123\n" == Just (Generation 123)
              , createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000002.json#123\n" == Nothing
              , createdGeneration prefix name "Created gs://example-bucket/private/inventory/journal/00000000000000000001.json#bad\n" == Nothing ]
  unless (and cases) (fail "createdGeneration checks failed")
  putStrLn "ObjectOps compiled; 3 exact-generation parser checks passed"
