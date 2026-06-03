-- This module is EXPECTED TO FAIL TO COMPILE.
--
-- It demonstrates that ServiceName's data constructor is inaccessible outside
-- Nagare.Dsl.Types, making it impossible to bypass mkServiceName's validation.
-- Do NOT add this module to a cabal stanza; verify it with
-- check-negative-types.sh.
module BadConstructor where

import Nagare.Dsl.Types (ServiceName)

-- Expected GHC error: "Not in scope: data constructor 'ServiceName'", because
-- Nagare.Dsl.Types exports the type 'ServiceName' but not its constructor.
badName :: ServiceName
badName = ServiceName "INVALID NAME WITH SPACES"
