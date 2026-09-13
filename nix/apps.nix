{ ... }:

{
  perSystem = { nagarePackages, ... }:
    let
      app = {
        type = "app";
        program = "${nagarePackages.nagarectl}/bin/nagarectl";
      };
    in
    {
      apps = {
        nagarectl = app;
        nagare = {
          type = "app";
          program = "${nagarePackages.nagare}/bin/nagare";
        };
        default = app;
      };
    };
}
