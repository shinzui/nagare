-- | EP-262: the En tenants an operator declares in a context, beside Nagare's
-- own tenant @nagare@. @NAGARE_EN_TENANTS@ lists them, and each names its
-- schema file in @NAGARE_EN_TENANT_<NAME>_SCHEMA@, where @<NAME>@ is the tenant
-- name upper-cased with @-@ replaced by @_@, as En names its own variables.
--
-- Parsing never reads the schema file: every command parses the context, and
-- one held without the operator repository must still work. The auth scope
-- reads the file when it compiles.
module Nagare.Target.EnTenants
  ( EnTenantName
  , mkEnTenantName
  , enTenantNameText
  , enTenantEnvName
  , EnTenantDeclaration (..)
  , parseEnTenantDeclarations
  , renderEnTenantDeclarations
  , enTenantSchemaVariable
  , readEnTenantSchema
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isDigit)
import Data.Generics.Labels ()
import Data.List (nub, (\\))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Traversable (for)
import Nagare.Dsl.Prelude
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath (isAbsolute, takeDirectory, (</>))

-- | A tenant name in En's grammar: a lower-case letter followed by at most 30
-- lower-case letters, digits or @-@.
newtype EnTenantName = EnTenantName Text
  deriving stock (Eq, Ord, Show)

mkEnTenantName :: Text -> Either Text EnTenantName
mkEnTenantName raw = case T.uncons raw of
  Just (first', rest)
    | isAsciiLower first'
    , T.length raw <= 31
    , T.all (\c -> isAsciiLower c || isDigit c || c == '-') rest ->
        Right (EnTenantName raw)
  _ -> Left ("En tenant name " <> T.pack (show raw) <> " must be a lower-case letter followed by at most 30 lower-case letters, digits or -")

enTenantNameText :: EnTenantName -> Text
enTenantNameText (EnTenantName name) = name

-- | The tenant's part of a variable name: @team-a@ is @TEAM_A@.
enTenantEnvName :: EnTenantName -> Text
enTenantEnvName = T.toUpper . T.replace "-" "_" . enTenantNameText

-- | One declared tenant and its schema path, as the context wrote it.
data EnTenantDeclaration = EnTenantDeclaration
  { name :: !EnTenantName
  , schemaPath :: !Text
  }
  deriving stock (Generic, Eq, Show)

enTenantSchemaVariable :: EnTenantName -> Text
enTenantSchemaVariable tenant = "NAGARE_EN_TENANT_" <> enTenantEnvName tenant <> "_SCHEMA"

-- | The declared tenants, in declaration order. Refuses an invalid, duplicate
-- or reserved name, a tenant with no schema, and any @NAGARE_EN_TENANT_@
-- variable that is not a declared tenant's schema (a typo, or a tenant missing
-- from the list).
parseEnTenantDeclarations :: Map String Text -> Either Text [EnTenantDeclaration]
parseEnTenantDeclarations ctx = do
  let listed = filter (not . T.null) (map T.strip (T.splitOn "," (Map.findWithDefault "" "NAGARE_EN_TENANTS" ctx)))
  names <- traverse mkEnTenantName listed
  when (EnTenantName "nagare" `elem` names) (Left "En tenant nagare is Nagare's own; choose another name in NAGARE_EN_TENANTS")
  case names \\ nub names of
    duplicate : _ -> Left ("NAGARE_EN_TENANTS names " <> enTenantNameText duplicate <> " twice")
    [] -> Right ()
  let expected = map enTenantSchemaVariable names
      stray =
        [ T.pack key
        | key <- Map.keys ctx
        , "NAGARE_EN_TENANT_" `T.isPrefixOf` T.pack key
        , T.pack key `notElem` expected
        ]
  case stray of
    key : _ -> Left (key <> " names no tenant in NAGARE_EN_TENANTS")
    [] -> Right ()
  for names $ \tenant -> case T.strip <$> Map.lookup (T.unpack (enTenantSchemaVariable tenant)) ctx of
    Just path | not (T.null path) -> Right (EnTenantDeclaration tenant path)
    _ -> Left ("En tenant " <> enTenantNameText tenant <> " needs its schema file in " <> enTenantSchemaVariable tenant)

-- | The context variables of the declared tenants, verbatim, as
-- @nagarectl context env@ prints them; none when there are none.
renderEnTenantDeclarations :: [EnTenantDeclaration] -> [(Text, Text)]
renderEnTenantDeclarations [] = []
renderEnTenantDeclarations tenants =
  ("NAGARE_EN_TENANTS", T.intercalate "," [enTenantNameText (tenant ^. #name) | tenant <- tenants])
    : [(enTenantSchemaVariable (tenant ^. #name), tenant ^. #schemaPath) | tenant <- tenants]

-- | Read a declared tenant's schema. A relative path is resolved against the
-- directory of the context file after following its symlinks, so a context
-- linked from the operator repository finds its schema there. A missing path,
-- or one that is not a file, is refused.
readEnTenantSchema :: FilePath -> EnTenantDeclaration -> IO (Either Text ByteString)
readEnTenantSchema contextFile tenant = do
  let declared = T.unpack (tenant ^. #schemaPath)
  path <-
    if isAbsolute declared
      then pure declared
      else (</> declared) . takeDirectory <$> canonicalizePath contextFile
  present <- doesFileExist path
  if not present
    then pure (Left (refusal path))
    else first (\(_ :: IOException) -> refusal path) <$> try (BS.readFile path)
  where
    refusal path = "En tenant " <> enTenantNameText (tenant ^. #name) <> "'s schema " <> T.pack path <> " is missing or not a file"
