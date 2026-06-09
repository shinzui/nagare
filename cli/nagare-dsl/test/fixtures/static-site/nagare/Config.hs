{-# LANGUAGE OverloadedStrings #-}

-- | Static-site config-as-program fixture — the surface file a static project
-- author ships. The loader compiles-and-runs it; every field is built through a
-- smart constructor, so a bad value is a compile-time or load-time error, never
-- a silent cluster rejection. Exercises one custom domain, one redirect, one
-- header rule, an immutable-asset cache policy with a default max-age, and a
-- 404 page.
module Main (main) where

import Nagare.Dsl.Config (emitStaticSite)
import Nagare.Dsl.Static.Types
import Nagare.Dsl.Types (mkDomain, mkImageRef, mkNamespace)

staticSite :: Either String StaticSite
staticSite = do
  name' <- mapLeft show (mkSiteName "notes")
  ns' <- mapLeft show (mkNamespace "personal")
  img' <- mapLeft show (mkImageRef "us-west1-docker.pkg.dev/tan-nb-exp/nagare/notes")
  outDir <- mapLeft show (mkFilePathText "dist")
  dom' <- mapLeft show (mkDomain "notes.example.com")
  redirect' <- mapLeft show (mkRedirectRule "/old" "/new" 301)
  header' <- mapLeft show (mkHeaderRule "/assets/" "X-Frame-Options" "DENY")
  cache' <- mapLeft show (mkCachePolicy True (Just 3600))
  notFound' <- mapLeft show (mkFilePathText "404.html")
  Right
    StaticSite
      { name = name'
      , namespace = ns'
      , image = img'
      , build = BuildCommand {command = "npm run build", outputDirectory = outDir}
      , domains = [dom']
      , redirects = [redirect']
      , headers = [header']
      , cache = cache'
      , notFound = Just notFound'
      }
  where
    mapLeft f = either (Left . f) Right

main :: IO ()
main = case staticSite of
  Left err -> ioError (userError err)
  Right s -> emitStaticSite s
