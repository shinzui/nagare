--| JTBD use-case profile. Bump the tag and semantic hash together when
-- upgrading.
let Profiles =
      https://raw.githubusercontent.com/shinzui/okf-profiles/v0.12.0/package.dhall
        sha256:97867b2364b6f9604ad6678ba246b704e1e16054c1ecebecc64db4e92c33b754

in  Profiles.coordination.useCases
