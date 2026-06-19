# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{
  pkgs ? import <nixpkgs> { },
}:

rec {
  mkShell = pkgs.callPackage ./mk-shell.nix { };
  overrideImports = pkgs.callPackage ./override-imports.nix { };
  fetch-nix-fod = pkgs.callPackage ./fetch-nix-fod.nix { };
  realize-nix-fod = pkgs.callPackage ./realize-nix-fod.nix { inherit fetch-nix-fod; };
  with-nix-sources = pkgs.callPackage ./with-nix-sources.nix { };
  nix-build-remotely = pkgs.callPackage ./nix-build-remotely.nix { };
}
