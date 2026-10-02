-- | Support.Environment responsibilities; internal implementation behind Nagare.Test.
module Nagare.Test.Support.Environment
  ( withTestEnv
  )
where

import Control.Exception (finally)
import Nagare.Dsl.Prelude hiding ((<.>))
import System.Environment (lookupEnv, setEnv, unsetEnv)

withTestEnv :: [(String, Maybe String)] -> IO a -> IO a
withTestEnv changes action = do
  saved <- traverse (\(name, _) -> (,) name <$> lookupEnv name) changes
  let apply (name, Just value) = setEnv name value
      apply (name, Nothing) = unsetEnv name
  mapM_ apply changes
  action `finally` mapM_ apply saved
