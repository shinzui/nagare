-- | EP-183 M2 (ADR 25): a stateful fake of the object-store tools the prune
-- Jobs call, so their shells run against a world instead of a script of
-- expected calls. One Python program backs @gcloud@, @curl@ and @aws@ through
-- @/bin/sh@ shims; its state is a JSON file of keys and their versions.
--
-- GCS semantics: a key has at most one live generation; a generation-matched
-- @rm@ makes it noncurrent (the backup bucket is versioned), and the JSON API
-- answers 404 when no live generation exists. S3 (MinIO) semantics: a delete
-- by version ID removes that version permanently.
--
-- A fault fires at the n-th tool call: 'FailBefore' fails it with no effect,
-- 'FailAfter' applies its effect and then reports failure, as a lost
-- acknowledgement does, and 'ErrorStatus' makes an HTTP request succeed with
-- a 503 answer (any other tool fails before effect).
module Nagare.Test.World.Bucket
  ( BucketVersion (..)
  , BucketState (..)
  , BucketFault (..)
  , FaultMode (..)
  , installBucketTools
  , writeBucketState
  , readBucketState
  , bucketEnvironment
  )
where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Nagare.Dsl.Prelude hiding ((.=))
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

data BucketVersion = BucketVersion
  { version :: !Text
  , content :: !Text
  , live :: !Bool
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON BucketVersion where
  toJSON (BucketVersion selected body current) = object ["version" .= selected, "data" .= body, "live" .= current]

instance FromJSON BucketVersion where
  parseJSON = withObject "BucketVersion" $ \o -> BucketVersion <$> o .: "version" <*> o .: "data" <*> o .: "live"

data FaultMode = FailBefore | FailAfter | ErrorStatus
  deriving stock (Eq, Show, Bounded, Enum, Generic)

data BucketFault = BucketFault
  { at :: !Int
  , mode :: !FaultMode
  }
  deriving stock (Eq, Show, Generic)

modeName :: FaultMode -> Text
modeName = \case
  FailBefore -> "before"
  FailAfter -> "after"
  ErrorStatus -> "status"

data BucketState = BucketState
  { calls :: !Int
  , fault :: !(Maybe BucketFault)
  , objects :: !(Map.Map Text [BucketVersion])
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BucketState where
  toJSON (BucketState count selected keys) =
    object
      [ "calls" .= count
      , "fault" .= fmap (\(BucketFault n selectedMode) -> object ["at" .= n, "mode" .= modeName selectedMode]) selected
      , "objects" .= keys
      ]

instance FromJSON BucketState where
  parseJSON = withObject "BucketState" $ \o -> do
    count <- o .: "calls"
    raw <- o .: "fault"
    selected <- case raw of
      Aeson.Null -> pure Nothing
      other -> Just <$> withObject "BucketFault" (\f -> BucketFault <$> f .: "at" <*> (f .: "mode" >>= \name -> maybe (fail "unknown fault mode") pure (lookup name [(modeName m, m) | m <- [minBound .. maxBound]]))) other
    BucketState count selected <$> o .: "objects"

writeBucketState :: FilePath -> BucketState -> IO ()
writeBucketState directory = LBS.writeFile (directory </> "state.json") . Aeson.encode

readBucketState :: FilePath -> IO BucketState
readBucketState directory = Aeson.eitherDecodeFileStrict (directory </> "state.json") >>= either fail pure

-- | The variables a shell under test needs to reach the fake tools first.
bucketEnvironment :: FilePath -> String -> [(String, String)]
bucketEnvironment directory path =
  [ ("PATH", directory <> ":" <> path)
  , ("NAGARE_FAKE_BUCKET_STATE", directory </> "state.json")
  , ("NAGARE_VERSION_LIST_FILE", directory </> "versions.json")
  ]

installBucketTools :: FilePath -> IO ()
installBucketTools directory = do
  writeFile (directory </> "bucket.py") program
  forM_ ["gcloud", "curl", "aws"] $ \tool -> do
    let shim = directory </> tool
    writeFile shim ("#!/bin/sh\nexec python3 \"" <> directory </> "bucket.py\" " <> tool <> " \"$@\"\n")
    setFileMode shim 0o755
  writeFile (directory </> "dnf") "#!/bin/sh\nexit 0\n"
  setFileMode (directory </> "dnf") 0o755

program :: String
program =
  unlines
    [ "import json, os, sys, urllib.parse"
    , "STATE = os.environ['NAGARE_FAKE_BUCKET_STATE']"
    , "tool, args = sys.argv[1], sys.argv[2:]"
    , "with open(STATE) as f: state = json.load(f)"
    , "state['calls'] += 1"
    , "fault = state.get('fault')"
    , "firing = fault is not None and fault['at'] == state['calls']"
    , "out = []"
    , "raw = None"
    , "def save():"
    , "    with open(STATE, 'w') as f: json.dump(state, f)"
    , "def fail(message, code=1):"
    , "    save(); sys.stderr.write(message + '\\n'); sys.exit(code)"
    , "if firing and fault['mode'] == 'status' and tool == 'curl':"
    , "    save(); sys.stdout.write('503'); sys.exit(0)"
    , "if firing and fault['mode'] in ('before', 'status'): fail('injected failure before effect')"
    , "objs = state['objects']"
    , "def live(key):"
    , "    found = [v for v in objs.get(key, []) if v['live']]"
    , "    return found[-1] if found else None"
    , "def find(key, version):"
    , "    found = [v for v in objs.get(key, []) if v['version'] == version]"
    , "    return found[0] if found else None"
    , "def gs(url):"
    , "    if not url.startswith('gs://'): fail('not a gs URL')"
    , "    return url[5:].split('/', 1)[1]"
    , "def opt(name):"
    , "    for i, a in enumerate(args):"
    , "        if a == name: return args[i + 1]"
    , "        if a.startswith(name + '='): return a.split('=', 1)[1]"
    , "    return None"
    , "if tool == 'gcloud':"
    , "    if args[:2] == ['auth', 'print-access-token']: out.append('token')"
    , "    elif args[:3] == ['storage', 'objects', 'describe']:"
    , "        v = live(gs(args[3]))"
    , "        if v is None: fail('ERROR: NotFound')"
    , "        out.append(v['version'])"
    , "    elif args[:2] == ['storage', 'cp'] and args[3] == '-':"
    , "        url, _, gen = args[2].partition('#')"
    , "        v = find(gs(url), gen)"
    , "        if v is None: fail('ERROR: NotFound')"
    , "        raw = v['data']"
    , "    elif args[:2] == ['storage', 'rm']:"
    , "        v = live(gs(args[2]))"
    , "        if v is None or opt('--if-generation-match') != v['version']: fail('ERROR: PreconditionFailed', 1)"
    , "        v['live'] = False"
    , "    else: fail('unsupported gcloud call: ' + ' '.join(args), 2)"
    , "elif tool == 'curl':"
    , "    url = args[-1]"
    , "    marker = '/storage/v1/b/'"
    , "    if marker not in url or '/o/' not in url: fail('unsupported curl URL', 2)"
    , "    key = urllib.parse.unquote(url.split('/o/', 1)[1])"
    , "    out.append('200' if live(key) is not None else '404')"
    , "elif tool == 'aws':"
    , "    rest = [a for a in args if a != '--no-paginate']"
    , "    command = rest[1] if rest[0] == 's3api' else fail('unsupported aws call', 2)"
    , "    key = opt('--key')"
    , "    if command == 'list-object-versions':"
    , "        prefix = opt('--prefix')"
    , "        versions = [{'Key': k, 'VersionId': v['version'], 'IsLatest': v is live(k)} for k in sorted(objs) if k.startswith(prefix) for v in objs[k]]"
    , "        out.append(json.dumps({'IsTruncated': False, 'Versions': versions}))"
    , "    elif command == 'list-objects-v2':"
    , "        prefix = opt('--prefix')"
    , "        keys = [k for k in sorted(objs) if k.startswith(prefix) and live(k) is not None]"
    , "        out.append('\\t'.join(keys) if keys else 'None')"
    , "    elif command == 'head-object':"
    , "        v = live(key)"
    , "        if v is None: fail('An error occurred (404)', 254)"
    , "        out.append(v['version'])"
    , "    elif command == 'get-object':"
    , "        v = find(key, opt('--version-id'))"
    , "        if v is None: fail('An error occurred (NoSuchVersion)', 254)"
    , "        with open(rest[-1], 'w') as f: f.write(v['data'])"
    , "    elif command == 'delete-object':"
    , "        selected = opt('--version-id')"
    , "        objs[key] = [v for v in objs.get(key, []) if v['version'] != selected]"
    , "        if not objs[key]: del objs[key]"
    , "    else: fail('unsupported aws call: ' + command, 2)"
    , "else: fail('unknown tool', 2)"
    , "if firing and fault['mode'] == 'after': fail('injected failure after effect')"
    , "save()"
    , "if raw is not None: sys.stdout.write(raw)"
    , "if out: sys.stdout.write('\\n'.join(out) + ('' if tool == 'curl' else '\\n'))"
    ]
