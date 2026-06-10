{-# LANGUAGE OverloadedStrings #-}

-- | Static-site descriptor for the @static-site@ example — the
-- config-as-program surface file a static project author ships (EP-14).
--
-- @nagarectl site deploy@ compiles-and-runs this file with @runghc@; every field
-- is built through EP-13's smart constructors, so an invalid value (a non-DNS
-- name, an absolute output directory, an out-of-range redirect status, a header
-- name with a colon) is a compile-time or load-time error here — never a silent
-- cluster rejection.
--
-- This example uses @NoBuild "public"@: the files in @public/@ are served
-- as-is, so @nagarectl site deploy --skip-build@ (or a plain deploy) needs no
-- Node toolchain. A framework project would instead use
-- @BuildCommand { command = "npm run build", outputDirectory = ... }@.
module Main (main) where

import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- mapLeft show (mkSiteName "static-site")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/static-site")
  dir' <- mapLeft show (mkFilePathText "public")
  redirect' <- mapLeft show (mkRedirectRule "/old-home" "/" 301)
  header' <- mapLeft show (mkHeaderRule "/assets/" "X-Content-Type-Options" "nosniff")
  cache' <- mapLeft show (mkCachePolicy True (Just 600))
  notFound' <- mapLeft show (mkFilePathText "404.html")
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = NoBuild dir'
      , domains = []
      , redirects = [redirect']
      , headers = [header']
      , cache = cache'
      , notFound = Just notFound'
      , cdn = Nothing
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
