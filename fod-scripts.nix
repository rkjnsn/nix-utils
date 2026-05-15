# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{
  writeShellScriptBin,
  python3,
  curl,
  gnugrep,
  coreutils,
  xz,
  bzip2,
  zstd,
  gnused,
  nix,
}:

rec {
  fetch-nix-fod = writeShellScriptBin "fetch-nix-fod" ''
    set -euo pipefail

    usage() {
      echo "Fetch a fixed-output derivation's content from cache.nixos.org." >&2
      echo "" >&2
      echo "Usage: $0 [-r] [-o output] <sha256-hex> <name>" >&2
      echo "  -r          recursive (directory) mode" >&2
      echo "  -o output   output path (default: ./<name>)" >&2
      echo "  sha256-hex  expected content hash in hexadecimal" >&2
      echo "  name        derivation name (e.g., foo.tar.gz)" >&2
      exit "''${1:-1}"
    }

    recursive=false
    output=""
    positional=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -r) recursive=true; shift ;;
        -o) [ $# -ge 2 ] || usage; output="$2"; shift 2 ;;
        -h|--help) usage 0 ;;
        -*) usage ;;
        *) positional+=("$1"); shift ;;
      esac
    done

    [ ''${#positional[@]} -eq 2 ] || usage
    hash_hex="''${positional[0]}"
    name="''${positional[1]}"
    output="''${output:-./$name}"

    store_hash=$(${python3}/bin/python3 - "$hash_hex" "$name" "$recursive" <<EOF
    import hashlib, sys

    nix32_chars = '0123456789abcdfghijklmnpqrsvwxyz'

    def to_nix32(data):
        bit_count = len(data) * 8
        hash_len = (bit_count + 4) // 5
        result = []
        for n in range(hash_len - 1, -1, -1):
            b = 0
            for bit in range(5):
                src_bit = n * 5 + bit
                if src_bit < bit_count:
                    byte_idx = src_bit // 8
                    bit_idx = src_bit % 8
                    if data[byte_idx] & (1 << bit_idx):
                        b |= 1 << bit
            result.append(nix32_chars[b])
        return '''.join(result)

    def compress_hash(h, new_size):
        result = bytearray(new_size)
        for i, b in enumerate(h):
            result[i % new_size] ^= b
        return bytes(result)

    hash_hex = sys.argv[1]
    name = sys.argv[2]
    recursive = sys.argv[3] == 'true'

    if recursive:
        fingerprint = 'source:sha256:' + hash_hex + ':/nix/store:' + name
    else:
        inner = hashlib.sha256(('fixed:out:sha256:' + hash_hex + ':').encode()).hexdigest()
        fingerprint = 'output:out:sha256:' + inner + ':/nix/store:' + name

    digest = hashlib.sha256(fingerprint.encode()).digest()
    compressed = compress_hash(digest, 20)
    print(to_nix32(compressed))
    EOF
    )

    echo "Querying cache for $store_hash..." >&2

    narinfo=$(${curl}/bin/curl -sfL "https://cache.nixos.org/$store_hash.narinfo") || {
      echo "error: not found in cache.nixos.org" >&2; exit 1
    }

    nar_url=$(echo "$narinfo" | ${gnugrep}/bin/grep '^URL:' | ${coreutils}/bin/cut -d' ' -f2)
    compression=$(echo "$narinfo" | ${gnugrep}/bin/grep '^Compression:' | ${coreutils}/bin/cut -d' ' -f2)
    [ -n "$nar_url" ] || { echo "error: narinfo missing URL field" >&2; exit 1; }
    [ -n "$compression" ] || { echo "error: narinfo missing Compression field" >&2; exit 1; }

    echo "Downloading: $nar_url ($compression)" >&2

    case "$compression" in
      xz)   decompress="${xz}/bin/xz -d" ;;
      bzip2) decompress="${bzip2}/bin/bzip2 -d" ;;
      zstd)  decompress="${zstd}/bin/zstd -d" ;;
      none)  decompress="${coreutils}/bin/cat" ;;
      *)     echo "error: unsupported compression: $compression" >&2; exit 1 ;;
    esac

    ${curl}/bin/curl -sfL "https://cache.nixos.org/$nar_url" | $decompress | ${nix}/bin/nix-store --restore "$output"

    actual=$(${nix}/bin/nix-hash --type sha256 $($recursive || echo --flat) "$output")
    [ "$actual" = "$hash_hex" ] || { echo "error: hash mismatch: expected $hash_hex, got $actual" >&2; exit 1; }

    echo "Written: $output" >&2
  '';

  realize-nix-fod = writeShellScriptBin "realize-nix-fod" ''
    set -euo pipefail

    usage() {
      echo "Parse a .drv file and fetch its fixed-output content into the Nix store." >&2
      echo "" >&2
      echo "Usage: $0 <path-to-.drv>" >&2
      exit "''${1:-1}"
    }

    case "''${1:-}" in
      -h|--help) usage 0 ;;
    esac

    [ $# -eq 1 ] || usage
    drv="$1"

    [ -f "$drv" ] || { echo "error: $drv not found" >&2; exit 1; }

    drv_content=$(< "$drv")

    extract() {
      echo "$1" | ${gnugrep}/bin/grep -o "$2" | ${gnused}/bin/sed "s/$2/\1/"
    }

    # Derive([("out","/nix/store/...","r:sha256","<hex>")],…[…("name","<name>")…])
    hash_algo=$(extract "$drv_content" '^Derive(\[("[^"]*","[^"]*","\([^"]*\)","[^"]*")')
    hash_hex=$(extract "$drv_content" '^Derive(\[("[^"]*","[^"]*","[^"]*","\([^"]*\)")')
    name=$(extract "$drv_content" '("name","\([^"]*\)")')

    case "$hash_algo" in
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
  '';
}
