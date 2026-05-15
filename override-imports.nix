# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{ lib, runCommand, coreutils, jq }:

src: overrides:

let
  doOverride = name: overrideFile:
    let
      captures = builtins.match "(.*)\\.nix" name;
      stem =
        if captures == null
        then throw "override target must have .nix extension: ${name}"
        else builtins.elemAt captures 0;
    in
    ''
      target_stem="$out"/${lib.escapeShellArg stem}

      if [ ! -f "$target_stem.nix" ]; then
        echo "error: override target not found: "${lib.escapeShellArg name} >&2
        exit 1
      fi

      n=0
      while [ -e "$target_stem.orig.$n.nix" ]; do
        n=$((n + 1))
      done
      orig_name="$target_stem.orig.$n.nix"

      ${coreutils}/bin/chmod u+w "$(${coreutils}/bin/dirname "$target_stem")"
      ${coreutils}/bin/mv "$target_stem.nix" "$orig_name"

      cat << EOF > "$target_stem.nix"
      import ${lib.strings.escapeNixString overrideFile} (
        import $(printf '%s' "$orig_name" | ${jq}/bin/jq -R -s .)
      )
      EOF
    '';
in
runCommand "overridden" {} ''
  ${coreutils}/bin/cp -a "${src}" "$out"

  ${builtins.concatStringsSep "\n"
    (lib.mapAttrsToList doOverride overrides)}
''
