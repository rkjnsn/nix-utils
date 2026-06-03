# SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
# SPDX-License-Identifier: MIT

{
  writeShellScriptBin,
  python3,
  openssh,
  nix,
  coreutils,
  gawk,
}:

writeShellScriptBin "nix-build-remotely" ''
  set -euo pipefail
  shopt -s lastpipe

  usage() {
    echo "Build a Nix derivation on a remote machine and copy results back.

  Usage: $0 [options] <remote> <nix-instantiate args...> [-- <nix-store --realise args...>]
         $0 [options] -d <remote> <drv-path>... [-- <nix-store --realise args...>]
    -d, --drv                   provide .drv paths directly instead of running
                                nix-instantiate
    -n, --no-send-deps          don't send any outputs from the drv closure to
                                the remote before building
    -b, --copy-build-closure    copy back all build outputs, not just the runtime
                                closure
    -f, --copy-on-failure       with -b, copy back successfully-built
                                dependencies even if the build fails
    -o, --outlink <path>        create a GC root symlink at <path> after target
                                is successfully built and copied back; multiple
                                results are named <path>, <path>-2, et cetera
    -s, --use-substitutes       when copying paths between machines, prefer
                                substituting on the destination over copying
                                when possible; doesn't impact whether
                                substitutions are used when building
    -i, --ignore-local          try to build the target remotely even if it
                                already exists locally (but still send its deps)" >&2
    exit "''${1:-1}"
  }

  # Given a list of .drv paths, print the full set of source inputs needed to
  # build them: direct src inputs plus the required output paths of drv inputs.
  collect_src_inputs() {
    ${python3}/bin/python3 -c '
  import ast, sys

  def parse_drv(path):
    with open(path) as f:
      raw = f.read().strip()
    if not raw.startswith("Derive(") or not raw.endswith(")"):
      print(f"ERROR: {path}: not a Derive(...) file", file=sys.stderr)
      sys.exit(1)
    return ast.literal_eval(f"({raw[7:-1]},)")

  src_inputs = set()
  drv_inputs = {}

  for path in sys.argv[1:]:
    parsed = parse_drv(path)
    for src in parsed[2]:
      src_inputs.add(src)
    for drv, outs in parsed[1]:
      drv_inputs.setdefault(drv, set()).update(outs)

  for drv_path, needed_outs in drv_inputs.items():
    parsed = parse_drv(drv_path)
    for name, path_, *_ in parsed[0]:
      if name in needed_outs:
        src_inputs.add(path_)

  for path in src_inputs:
    print(path)
  ' "$@"
  }

  use_drv=false
  send_outputs=true
  copy_build_closure=false
  copy_on_failure=false
  ignore_local=false
  copy_closure_opts=()
  outlink=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help) usage 0 ;;
      -d|--drv) use_drv=true; shift ;;
      -n|--no-send-deps) send_outputs=false; shift ;;
      -b|--copy-build-closure) copy_build_closure=true; shift ;;
      -f|--copy-on-failure) copy_on_failure=true; shift ;;
      -o|--outlink) outlink="$2"; shift 2 ;;
      -s|--use-substitutes) copy_closure_opts+=(--use-substitutes); shift ;;
      -i|--ignore-local) ignore_local=true; shift ;;
      -*) usage ;;
      *) break ;;
    esac
  done

  if $copy_on_failure && ! $copy_build_closure; then
    echo "error: --copy-on-failure requires --copy-build-closure" >&2
    exit 1
  fi

  [[ $# -ge 1 ]] || usage
  remote="$1"; shift

  instantiate_args=()
  realise_args=()
  past_separator=false
  for arg in "$@"; do
    if [[ "$arg" == "--" ]] && ! $past_separator; then
      past_separator=true
      continue
    fi
    if $past_separator; then
      realise_args+=("$arg")
    else
      instantiate_args+=("$arg")
    fi
  done

  [[ ''${#instantiate_args[@]} -ge 1 ]] || usage

  if $use_drv; then
    drv=("''${instantiate_args[@]}")
  else
    echo "Instantiating derivations..." >&2
    ${nix}/bin/nix-instantiate "''${instantiate_args[@]}" | mapfile -t drv
  fi

  ctl=$(${coreutils}/bin/mktemp -u /tmp/nix-remote-XXXXXX)
  cleanup() { ${openssh}/bin/ssh -O exit -o ControlPath="$ctl" "$remote" 2>/dev/null || true; }
  trap cleanup EXIT

  export NIX_SSHOPTS="''${NIX_SSHOPTS:+$NIX_SSHOPTS }-o ControlPath=$ctl"

  ${openssh}/bin/ssh -fNM $NIX_SSHOPTS "$remote"

  echo "Copying derivation closure to remote..." >&2
  ${nix}/bin/nix-copy-closure --gzip "''${copy_closure_opts[@]}" --to "$remote" "''${drv[@]}"

  if $send_outputs; then
    # Ask nix which derivations would actually need to be built to realise the
    # target locally. This excludes derivations whose needed outputs are already
    # present, so we don't send build inputs for, e.g., source fetches or
    # bootstrap stages that nothing needing building depends on.
    echo "Computing build plan..." >&2
    # Assume no substituters for local, since substitution happens on the remote
    ${nix}/bin/nix-store --realise --dry-run --substituters "" "''${drv[@]}" 2>&1 >/dev/null |
    ${gawk}/bin/awk '/derivation.* will be built:/{p=1; next} /^[^ ]/{p=0} p{print substr($0, 3)}' |
    mapfile -t to_build_local

    if $ignore_local; then
      to_build_local+=("''${drv[@]}")
    fi

    if [[ ''${#to_build_local[@]} -eq 0 ]]; then
      ${nix}/bin/nix-store --query --outputs "''${drv[@]}" | mapfile -t valid_input_paths
    else
      ${openssh}/bin/ssh $NIX_SSHOPTS "$remote" "$(printf '%q ' nix-store --realise "''${realise_args[@]}" --dry-run "''${drv[@]}")" 2>&1 >/dev/null |
      ${gawk}/bin/awk '/derivation.* will be built:/{p=1; next} /^[^ ]/{p=0} p{print substr($0, 3)}' |
      mapfile -t to_build_remote

      ${coreutils}/bin/comm -12 \
        <(printf '%s\n' "''${to_build_local[@]}" | ${coreutils}/bin/sort -u) \
        <(printf '%s\n' "''${to_build_remote[@]}" | ${coreutils}/bin/sort -u) |
      mapfile -t to_build

      build_input_paths=()
      if [[ ''${#to_build[@]} -gt 0 ]]; then
        collect_src_inputs "''${to_build[@]}" | mapfile -t build_input_paths
      fi

      valid_input_paths=()
      if [[ ''${#build_input_paths[@]} -gt 0 ]]; then
        ${nix}/bin/nix-store --check-validity --print-invalid "''${build_input_paths[@]}" |
        ${coreutils}/bin/sort -u |
        mapfile -t invalid_paths

        ${coreutils}/bin/comm -23 \
          <(printf '%s\n' "''${build_input_paths[@]}" | ${coreutils}/bin/sort -u) \
          <(printf '%s\n' "''${invalid_paths[@]}") |
        mapfile -t valid_input_paths
      fi
    fi

    if [[ ''${#valid_input_paths[@]} -gt 0 ]]; then
      echo "Sending build inputs..." >&2
      ${nix}/bin/nix-copy-closure --gzip "''${copy_closure_opts[@]}" --to "$remote" "''${valid_input_paths[@]}"
    fi
  fi

  echo "Building remotely..." >&2
  realise_rc=0
  ${openssh}/bin/ssh -t $NIX_SSHOPTS "$remote" "$(printf '%q ' nix-store --realise "''${realise_args[@]}" "''${drv[@]}")" || realise_rc=$?

  if [[ "$realise_rc" -ne 0 ]] && ! $copy_on_failure; then
    : # skip copy back
  elif $copy_build_closure; then
    if [[ "$realise_rc" -ne 0 ]]; then
      echo "copying back successfully-built dependencies..." >&2
    else
      echo "copying back all build outputs..." >&2
    fi
    ${nix}/bin/nix-copy-closure --gzip "''${copy_closure_opts[@]}" --from "$remote" --include-outputs "''${drv[@]}"
  else
    echo "Copying back output run-time closure..." >&2
    ${nix}/bin/nix-store --query --outputs "''${drv[@]}" | mapfile -t outputs
    ${nix}/bin/nix-copy-closure "''${copy_closure_opts[@]}" --from "$remote" "''${outputs[@]}"
  fi

  if [[ "$realise_rc" -ne 0 ]]; then
    echo "error: remote build failed with exit code $realise_rc" >&2
    exit "$realise_rc"
  fi

  if [[ -n "$outlink" ]]; then
    if $use_drv; then
      ${nix}/bin/nix-store --realise --add-root "$outlink" "''${drv[@]}" > /dev/null
    else
      ${nix}/bin/nix-build "''${instantiate_args[@]}" --out-link "$outlink" > /dev/null
    fi
  fi
''
