# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{
  pkgs ? import <nixpkgs> { },
}:

{
  mkShell = pkgs.callPackage ./mk-shell.nix { };
  overrideImports = pkgs.callPackage ./override-imports.nix { };
  inherit (pkgs.callPackage ./fod-scripts.nix { }) fetch-nix-fod realize-nix-fod;
  with-nix-sources = pkgs.callPackage ./with-nix-sources.nix { };
  nix-build-remotely = pkgs.callPackage ./nix-build-remotely.nix { };
}
