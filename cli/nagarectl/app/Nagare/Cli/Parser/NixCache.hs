-- | Parser / NixCache. Executable-private CLI boundary.
module Nagare.Cli.Parser.NixCache
  ( nixCacheCmd
  )
where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Nagare.Cli.Options (Command (..))
import Nagare.Cli.Options.NixCache
  ( NixCacheCommand (..)
  , NixCacheForwardOpts (..)
  , NixCachePushOpts (..)
  , NixCacheTokenOpts (..)
  )
import Nagare.Cli.Parser.Common (contractOpt)
import Nagare.Dsl.Prelude
import Options.Applicative
  ( Parser
  , ParserInfo
  , command
  , fullDesc
  , help
  , helper
  , info
  , long
  , many
  , metavar
  , optional
  , progDesc
  , strArgument
  , strOption
  , subparser
  , value
  , (<**>)
  )

nixCacheCmd :: ParserInfo Command
nixCacheCmd =
  info
    (NixCache <$> nixCacheSubparser <**> helper)
    (fullDesc <> progDesc "Publish signed Nix closures to the context's Attic cache")

nixCacheSubparser :: Parser NixCacheCommand
nixCacheSubparser =
  subparser
    ( command
        "token"
        ( info
            (NixCacheToken <$> tokenOpts <**> helper)
            (progDesc "Mint a pull-and-push token for nagare-cache into a new mode-0600 file")
        )
        <> command
          "forward"
          ( info
              (NixCacheForward . NixCacheForwardOpts <$> contractOpt <**> helper)
              (progDesc "Forward 127.0.0.1:18080 to the cache, print its endpoint and public key, and stay open until interrupted")
          )
        <> command
          "push"
          ( info
              (NixCachePush <$> pushOpts <**> helper)
              (progDesc "Push store paths and their closures to the context's cache, or with --endpoint to any Attic")
          )
    )

tokenOpts :: Parser NixCacheTokenOpts
tokenOpts =
  NixCacheTokenOpts
    <$> strOption (long "out" <> metavar "FILE" <> help "New file to write the token to (refused if it exists)")
    <*> strOption (long "subject" <> metavar "NAME" <> value "operator-push" <> help "Token subject (default operator-push)")
    <*> strOption (long "validity" <> metavar "DURATION" <> value "1h" <> help "Token lifetime, at most 24h (default 1h)")

pushOpts :: Parser NixCachePushOpts
pushOpts =
  NixCachePushOpts
    <$> optional (strOption (long "endpoint" <> metavar "URL" <> help "Push to this Attic instead of the context's cache (with --token-file)"))
    <*> optional (strOption (long "token-file" <> metavar "FILE" <> help "Token file for --endpoint"))
    <*> optional (strOption (long "cache" <> metavar "NAME" <> help "Cache name at --endpoint (default nagare-cache)"))
    <*> ((:|) <$> strArgument (metavar "STORE-PATH..." <> help "Store paths to push with their closures") <*> many (strArgument (metavar "STORE-PATH...")))
    <*> contractOpt
