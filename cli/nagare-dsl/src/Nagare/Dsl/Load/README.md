# Configuration loading boundaries

`Nagare.Dsl.Load` preserves its public API. All modules in this directory are
library-private. `Process` runs the config program with the existing timeout and
error behavior. `File` composes that operation with the appropriate decoder.
`Error` owns errors and timeout values. Domain modules decode and validate JSON;
`Fields` contains shared environment, volume, build, access, domain and health
fields, and `Site` selects the static/server variant.

Decoders must remain pure and must not depend on `Process` or `File`. Keep
constructors, defaults, discriminator handling and validation errors consistent
with `Nagare.Dsl.Config` encoders. No field or format change is implied by moving
a decoder. Tests continue to exercise both emitted JSON and real config programs.
