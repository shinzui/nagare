-- A shared "web service" shape (criterion-(c) reuse demo). App configs import
-- this and override what differs. `webService` is a Dhall function: given an app
-- name and image, it returns the common deployment record. Dhall's type-checker
-- validates every use site, and the `//` record-override operator (in
-- hello.dhall) composes this preset with per-app fields without copy-paste.
let webService =
      \(appName : Text) ->
      \(img : Text) ->
        { name = appName
        , namespace = "personal"
        , image = img
        , port = 8080
        , env =
            [] : List { varName : Text, kind : < Literal : Text | Secret : Text > }
        , cpuRequest = Some "250m"
        , memoryRequest = Some "512Mi"
        , scaleMin = Some 0
        , scaleMax = Some 3
        , domain = None Text
        }

in  webService
