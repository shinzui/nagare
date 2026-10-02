# Test ownership

`Spec.hs` enters `Nagare.Test.Suite`, which assembles the existing domain suites
and the modules under `Nagare.Test`. Add assertions to the matching domain;
keep suite assembly free of test implementations. Shared fixtures live under
`Nagare.Test.Support` by concern, with backup-specific inputs in `DataFixtures`.
Domain test modules do not import the suite assembler. Test names and ordering
are preserved so existing Tasty selection patterns keep working.

From `cli/nagarectl`, run `cabal test nagarectl-test --offline
--test-show-details=failures`. Use `--test-options='-p /Inventory.Site/'` for a
focused site-inventory run. Run the DSL and CLI suites sequentially: config
program tests use the local Cabal package environment.
