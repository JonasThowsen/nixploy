{ lib, beamPackages }:

let
  buildMix = lib.makeOverridable beamPackages.buildMix;
in
with beamPackages;
{
  expo =
    let
      version = "1.1.1";
    in
    buildMix {
      inherit version;
      name = "expo";
      appConfigPath = ./config;
      src = fetchHex {
        inherit version;
        pkg = "expo";
        sha256 = "5fb308b9cb359ae200b7e23d37c76978673aa1b06e2b3075d814ce12c5811640";
      };
    };
}
