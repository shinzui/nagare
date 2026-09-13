{ nagarePackages }:

let
  app = {
    type = "app";
    program = "${nagarePackages.nagarectl}/bin/nagarectl";
  };
in
{
  nagarectl = app;
  nagare = {
    type = "app";
    program = "${nagarePackages.nagare}/bin/nagare";
  };
  default = app;
}
