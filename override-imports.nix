# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{ lib, runCommand, coreutils, gnupatch, jq }:

src: args:

let
  patches = args.patches or [];
  overrides = removeAttrs args [ "patches" ];

  srcType = builtins.readFileType src;
  checkedSrc =
    if srcType == "directory" then src
    else if srcType == "symlink" then throw ''
      overrideImports: src must be a real directory, not a symlink: ${toString src}
      Hint: if src is a symlink to a store path, use builtins.storePath (toString src) to get the real store path without copying.
    ''
    else throw "overrideImports: src must be a directory (got type '${srcType}'): ${toString src}";

  doOverride = name: overridePath:
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
      orig_basename=${lib.escapeShellArg (baseNameOf stem)}".orig.$n.nix"

      ${coreutils}/bin/mv "$target_stem.nix" "$orig_name"

      # Reference the original by a path relative to the generated file (./. is
      # the file's own directory) rather than an absolute store path. This
      # ensures that if the tree is copied and modified further, the override
      # will import the new path.
      cat << EOF > "$target_stem.nix"
      import ${lib.strings.escapeNixString overridePath}
        (./. + $(printf '%s' "/$orig_basename" | ${jq}/bin/jq -R -s .))
      EOF
    '';
in
runCommand "overridden" {} ''
  ${coreutils}/bin/cp -a "${checkedSrc}" "$out"
  ${coreutils}/bin/chmod -R u+w "$out"

  ${lib.concatMapStringsSep "\n"
    (patch: ''
      echo "applying patch: "${lib.escapeShellArg "${patch}"}
      ${gnupatch}/bin/patch -p1 -d "$out" < ${lib.escapeShellArg "${patch}"}
    '')
    patches}

  ${builtins.concatStringsSep "\n"
    (lib.mapAttrsToList doOverride overrides)}
''
