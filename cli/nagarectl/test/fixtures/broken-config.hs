{-# LANGUAGE OverloadedStrings #-}

-- | A deliberately broken config-as-program fixture for the failure-path test
-- (EP-12 M3.3). The service name @"INVALID NAME"@ is not a DNS label, so EP-9's
-- 'mkServiceName' returns a 'Left' and this program errors out before emitting
-- any deployment. @loadDeployment@ surfaces that as a 'CompileError' and
-- @nagarectl@ prints a one-line message to stderr and exits 1 — proving an
-- invalid config never reaches the cluster. Kept as a regression fixture.
module Main (main) where

import Nagare.Dsl.Types (ServiceName, mkServiceName)

badName :: Either String ServiceName
badName = either (Left . show) Right (mkServiceName "INVALID NAME")

main :: IO ()
main = case badName of
  Left err -> ioError (userError err)
  Right _ -> pure ()
