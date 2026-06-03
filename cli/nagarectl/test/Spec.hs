-- | nagarectl test placeholder.
--
-- The YAML-era golden test (EP-6's @Nagare.Config@/@Nagare.Render@) was retired
-- in the EP-12 cutover; the authoritative renderer golden tests live in
-- @nagare-dsl-test@ (EP-9). nagarectl proper is thin orchestration over
-- @nagare-dsl@, validated behaviourally by @nagarectl deploy --dry-run@.
module Main (main) where

main :: IO ()
main = putStrLn "nagarectl-test: no unit tests yet (golden tests live in nagare-dsl-test)"
