-- Nagare deployment descriptor for the "hello" app — Prototype 3 (Dhall).
--
-- Reuse demo (criterion c): instead of repeating the full record, import the
-- shared `webService` preset from ./prelude.dhall, apply it to this app's name
-- and image, then layer this app's env vars on top with the `//` record-override
-- operator. Dhall's type-checker validates the composed result; there is no
-- copy-paste. Decoded by app/Proto3.hs via `Dhall.inputFile Dhall.auto`.

let webService = ./prelude.dhall

let EnvKind = < Literal : Text | Secret : Text >

let hello =
      webService "hello" "us-west1-docker.pkg.dev/tan-nb-exp/nagare/hello"

in  hello
    // { env =
         [ { varName = "DATABASE_URL", kind = EnvKind.Secret "hello-db-url" }
         , { varName = "LOG_LEVEL", kind = EnvKind.Literal "info" }
         ]
       }
