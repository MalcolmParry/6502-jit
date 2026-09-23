{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  packages = [
    pkgs.zig_0_16
    pkgs.zls_0_16
    pkgs.git
    pkgs._64tass
  ];
}
