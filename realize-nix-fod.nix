# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{
  writeShellScriptBin,
  fetch-nix-fod,
  gnugrep,
  gnused,
  coreutils,
  nix,
}:

writeShellScriptBin "realize-nix-fod" ''
  set -euo pipefail

  usage() {
    echo "Parse a .drv file and fetch its fixed-output content into the Nix store.

  Usage: $0 <path-to-.drv>" >&2
    exit "''${1:-1}"
  }

  case ''${1:-} in
    -h|--help) usage 0 ;;
  esac

  [[ $# -eq 1 ]] || usage
  drv="$1"

  [[ -f "$drv" ]] || { echo "error: $drv not found" >&2; exit 1; }

  drv_content=$(< "$drv")

  extract() {
    echo "$1" | ${gnugrep}/bin/grep -o "$2" | ${gnused}/bin/sed "s/$2/\1/"
  }

  # Derive([("out","/nix/store/<hash>-<name>","r:sha256","<hex>")],…)
  out_path=$(extract "$drv_content" '^Derive(\[("[^"]*","\([^"]*\)","[^"]*","[^"]*")')
  hash_algo=$(extract "$drv_content" '^Derive(\[("[^"]*","[^"]*","\([^"]*\)","[^"]*")')
  hash_hex=$(extract "$drv_content" '^Derive(\[("[^"]*","[^"]*","[^"]*","\([^"]*\)")')
  name=$(${coreutils}/bin/basename "$out_path" | ${gnused}/bin/sed 's/^[^-]*-//')

  case $hash_algo in
    r:sha256) recursive=true ;;
    sha256) recursive=false ;;
    *) echo "error: unsupported hash algorithm: $hash_algo" >&2; exit 1 ;;
  esac

  echo "Name: $name" >&2
  echo "Hash: $hash_hex" >&2
  echo "Mode: $($recursive && echo recursive || echo flat)" >&2

  tmpdir=$(${coreutils}/bin/mktemp -d)
  trap '${coreutils}/bin/rm -rf "$tmpdir"' EXIT

  ${fetch-nix-fod}/bin/fetch-nix-fod $($recursive && echo -r) -o "$tmpdir/$name" "$hash_hex" "$name"

  ${nix}/bin/nix-store --add-fixed $($recursive && echo --recursive) sha256 "$tmpdir/$name"
''
