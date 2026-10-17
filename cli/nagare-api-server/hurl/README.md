# The admin API's black-box suite

These files prove what the in-process suite cannot: the built `nagare-api-server` starts, binds,
installs its middleware and serves the public contract over a real socket.

`just api-hurl` builds the server, seeds a fixture store with the suite's own
`NAGARE_API_FIXTURE` probe (context `fixture`, project `project`: twelve sites `s1`…`s12` in
namespace `personal`, of which `s12` has not converged; the image publication
`publication:app-image-docs-v1/docs-v1/oci-image`, used by `application:docs`; a user grant on
`s1.example.com`, a team grant on `s2.example.com` and a user grant on `gone.example.com`), starts
the server on `127.0.0.1:18085`, runs `run.sh` and stops the server. Every file is read-only and
independent, so a rerun needs no cleanup. `run.sh` alone targets an already running server at
`base_url` in `vars.env`.
