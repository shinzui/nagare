{ ... }:

{
  perSystem = { lib, nagarePackages, isReleaseSystem, ... }:
    let
      app = {
        type = "app";
        program = "${nagarePackages.nagarectl}/bin/nagarectl";
      };
    in
    {
      apps = lib.optionalAttrs isReleaseSystem {
        nagarectl = app;
        nagare = {
          type = "app";
          program = "${nagarePackages.nagare}/bin/nagare";
        };
        default = app;
      };
    };
}
