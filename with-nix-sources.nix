# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{ writeShellScriptBin, coreutils, nix }:

writeShellScriptBin "with-nix-sources" ''
  set -euo pipefail

  usage() {
    echo "Usage: $0 PATH [PATH...] -- COMMAND [ARGS...]
       $0 -i|--instantiate PATH [PATH...]

  Each PATH should be an importable path (a .nix file or a directory with a
  default.nix) evaluating to an attribute set that maps channel names to Nix
  expressions coercible to paths (e.g., paths, derivations, or fetchTarball
  calls). These are prepended to NIX_PATH and COMMAND is executed with the
  new NIX_PATH set.

  -i, --instantiate  Print the derivation path for the resulting NIX_PATH
                     contents without building and exit." >&2
    exit "''${1:-1}"
  }

  instantiate=false
  files=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) usage 0 ;;
      -i|--instantiate) instantiate=true; shift ;;
      --) shift; break ;;
      *) files+=("$1"); shift ;;
    esac
  done

  if $instantiate; then
    [[ ''${#files[@]} -gt 0 && $# -eq 0 ]] || usage
  else
    [[ ''${#files[@]} -gt 0 && $# -gt 0 ]] || usage
  fi

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

  if $instantiate; then
    exec ${nix}/bin/nix-instantiate -E "$expr" "''${args[@]}"
  fi

  # Using nix-build to realize a file containing the NIX_PATH value
  # ensures that the constituent paths are also realized.
  nix_path=$(< "$(${nix}/bin/nix-build --no-out-link -E "$expr" "''${args[@]}")")
  if [[ -n $nix_path ]]; then
    export NIX_PATH="$nix_path''${NIX_PATH:+:$NIX_PATH}"
  fi
  exec "$@"
''
