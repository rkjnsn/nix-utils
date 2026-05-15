# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{ bash, stdenv }:

{
  name ? "shell",
  packages ? [ ],
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  env ? { },
  shellHook ? "",
}:
derivation {
  __structuredAttrs = true;
  strictDeps = true;
  system = builtins.currentSystem;
  builder = "${bash}/bin/bash";
  args = [
    "-c"
    "source $NIX_ATTRS_SH_FILE; printf '' > \${outputs[out]}"
  ];
  inherit stdenv;

  inherit name buildInputs env;
  nativeBuildInputs = nativeBuildInputs ++ packages;
  shellHook = ''
    unset out shell NIX_ATTRS_SH_FILE NIX_ATTRS_JSON_FILE __json
  ''
  + shellHook;
}
