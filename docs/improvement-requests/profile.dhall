--| Cross-repository improvement request profile. Bump the tag and semantic hash
-- together when upgrading.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.8.0/package.dhall
        sha256:0d66bb25b99e74a10598be06eef30356f331ff9c1c557e8578daf48cbd50d8d3

in  Profiles.coordination.improvementRequests
