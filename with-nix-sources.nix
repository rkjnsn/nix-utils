# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{ writeShellScriptBin, coreutils, nix }:

writeShellScriptBin "with-nix-sources" ''
  set -euo pipefail

  usage() {
    echo "Usage: $0 PATH [PATH...] -- COMMAND [ARGS...]

  Each PATH should be an importable path (a .nix file or a directory with a
  default.nix) evaluating to an attribute set that maps channel names to Nix
  expressions coercible to paths (e.g., paths, derivations, or fetchTarball
  calls). These are prepended to NIX_PATH and COMMAND is executed with the
  new NIX_PATH set." >&2
    exit "''${1:-1}"
  }

  files=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) usage 0 ;;
      --) shift; break ;;
      *) files+=("$1"); shift ;;
    esac
  done

  [[ ''${#files[@]} -gt 0 && $# -gt 0 ]] || usage

  args=()
  count=''${#files[@]}
  width=''${#count}
  for i in "''${!files[@]}"; do
    args+=(--argstr "$(printf "file%0''${width}d" "$i")" "$(${coreutils}/bin/realpath -- "''${files[$i]}")")
  done

  expr='{ ... }@args:
    let
      mapAttrsToList = f: set:
        builtins.attrValues (builtins.mapAttrs f set);
      sources = builtins.concatLists
        (mapAttrsToList
          (_: file: mapAttrsToList
            (name: path: "''${name}=''${path}")
            (import file))
          args);
      nixPath = builtins.concatStringsSep ":" sources;
    in
      derivation {
        name = "nix-path";
        system = builtins.currentSystem;
        builder = "/bin/sh";
        args = ["-c" "printf '%s' \"$nixPath\" > \"$out\""];
        inherit nixPath;
      }'

  # Using nix-build to realize a file containing the NIX_PATH value
  # ensures that the constituent paths are also realized.
  nix_path=$(< "$(${nix}/bin/nix-build --no-out-link -E "$expr" "''${args[@]}")")
  if [[ -n $nix_path ]]; then
    export NIX_PATH="$nix_path''${NIX_PATH:+:$NIX_PATH}"
  fi
  exec "$@"
''
