<!--
SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
SPDX-License-Identifier: MIT
-->

# nix-utils

A collection of personal Nix utilities.


## `mkShell`

An alternative to `pkgs.mkShell` that tries to keep the environment a little
cleaner.

```nix
nix-utils.mkShell {
  name = "my-project";
  packages = [ pkgs.rustc pkgs.cargo ];
  env = { CARGO_HOME = "${toString ./.}/.cargo"; };
  shellHook = ''export PATH="$CARGO_HOME/bin:$PATH"'';
}
```

**Parameters:**

- `name` -- Shell derivation name (default: `"shell"`)
- `packages` -- Packages to add to `nativeBuildInputs`
- `nativeBuildInputs` / `buildInputs` -- Standard dependency lists
- `env` -- Attribute set of environment variables
- `shellHook` -- Shell code to run on entry

## `overrideImports`

Takes a source tree and an attribute set mapping Nix filenames to override
paths. For each entry, the original file is renamed and replaced with a wrapper
that imports the override path, passing it a path value pointing to the
renamed original.

```nix
nix-utils.overrideImports sources.nixpkgs {
  "default.nix" = builtins.toFile "override.nix" ''
    orig: { overlays ? [], ... }@args:
    import orig (args // { overlays = [ (final: prev: { /* ... */ }) ] ++ overlays; })
  '';
}
```

Multiple overrides to the same file stack: each override wraps the
previous one, with originals preserved as `*.orig.N.nix`.

Useful when you want override a certain entry point but keep the directory
structure intact. (E.g., so `import <nixpkgs> {}` includes a desired overlay,
but `import <nixpkgs/lib>` still works.)

When the source is already in the Nix store (e.g., a fetched source or channel
path), wrap it with `builtins.storePath src` to reference it directly rather
than having nix copy it an extra time.

## `fetch-nix-fod`

A shell command that fetches the content of a fixed-output derivation from
`cache.nixos.org` given its expected SHA-256 hash and derivation name.

```
fetch-nix-fod [-r] [-o output] <sha256-hex> <name>
```

**Flags:**

- `-r` -- Recursive (directory) mode, for derivations with
  `outputHashMode = "recursive"`
- `-o output` -- Output path (default: `./<name>`)

The command computes the Nix store path from the hash and name, queries the
binary cache for a matching NAR, downloads and decompresses it, then
verifies the hash.

This effectively allows using cache.nixos.org as a mirror for source files,
even if not generally using it as a substituter.

## `realize-nix-fod`

A shell command that parses a `.drv` file for a fixed-output derivation,
extracts its hash and name, fetches the content via `fetch-nix-fod`, and
adds it to the local Nix store.

```
realize-nix-fod <path-to-.drv>
```

Use when you have an instantiated `.drv` file for a fixed-output derivation
and want to realize it by fetching from the binary cache when that wouldn't
otherwise be possible (e.g., because `cache.nixos.org` isn't configured as a
trusted substituter, or because one is using a non-standard store path). This
is useful when the normal fetch mechanism is unavailable (e.g., the source
website is down, or one is building an old nixpkgs and the file is no longer
available).

## `with-nix-sources`

A shell command that gathers channel paths from one or more Nix files and
executes a command with them prepended to `NIX_PATH`.

```
with-nix-sources PATH [PATH...] -- COMMAND [ARGS...]
```

Each path should be an importable Nix path (a `.nix` file or a directory
with a `default.nix`, such as an `npins` directory) evaluating to an
attribute set mapping channel names to Nix expressions coercible to paths
(paths, derivations, `fetchTarball` calls, etc.). The paths will be
realized, prepended to `NIX_PATH`, and the command executed.

```nix
# sources.nix
{
  nixpkgs = fetchTarball { url = "..."; sha256 = "..."; };
  nixpkgs-unstable = fetchTarball { url = "..."; sha256 = "..."; };
}
```

```
with-nix-sources sources.nix -- nix-build '<nixpkgs>' -A hello
```

One possible way to use npins with Home Manager:

In `home.nix`:

    nix.channels = {
      nixpkgs = builtins.storePath pkgs.path;
      home-manager = builtins.storePath (import <home-manager> { }).path;
    };

That way `<nixpkgs>` and `<home-manager>` will always refer to the channel
versions with which the current generation was built.

To update:

```
npins update
with-nix-sources ./npins -- home-manager switch
```

If the new generation builds and activates successfully, `<nixpkgs>` and
`<home-manager>` will refer to the updated versions.

## `nix-build-remotely`

A shell command that allows building a Nix derivation on a remote machine
without having to provide the nix daemon with passwordless SSH access to the
remote builder. Signing still has to be configured on the remote builder with
a key trusted by the local machine. Somewhat inspired by nixos-rebuild's remote
building functionality.

The script handles copying the derivation closure to the remote machine,
optionally (if `-n` isn't specified) sending any needed build inputs that exist
on the local machine, running the build remotely via ssh, and copying back the
result.

For sending build inputs to the remote machine to work, they need to be signed
by a key the remote system trusts. This might be because they were originally
built and signed by the remote machine (and since garbage collected there) or
because the local machine has its own signing key configured that is trusted
by the remote. If neither is the case, specify `-n` to skip copying deps.

```
nix-build-remotely [options] <remote> <nix-instantiate args...> [-- <nix-store --realise args...>]
nix-build-remotely [options] -d <remote> <drv-path>... [-- <nix-store --realise args...>]
```

### Options:

- `-d`, `--drv` -- Build these `.drv` paths instead of running `nix-instantiate`
- `-n`, `--no-send-deps` -- Don't send any locally available build inputs to
  the remote before building.
- `-b`, `--copy-build-closure` -- Copy back all build outputs, not just the
  runtime closure (see note below)
- `-f`, `--copy-on-failure` -- With `-b`, copy back successfully-built
  dependencies even if the build fails
- `-o`, `--outlink <path>` -- Create a GC root symlink at `<path>` after the
  target is successfully built and copied back; multiple results are named
  `<path>`, `<path>-2`, et cetera
- `-s`, `--use-substitutes` -- When copying paths between machines, prefer
  substituting on the destination over copying when possible; doesn't affect
  whether substitutions are used while building
- `-i`, `--ignore-local` -- Try to build the target remotely even if it
  already exists locally (but still send its deps).

Arguments after `--` are forwarded to the remote `nix-store --realise`
invocation (e.g., `--max-jobs`, `--cores`, `--log-format`, et cetera).

The command uses SSH connection multiplexing so you only have to enter your ssh
password once, and respects the `NIX_SSHOPTS` environment variable for
additional ssh options.

Note: The `-b` / `--copy-build-closure` relies on passing `--include-outputs`
to `nix-copy-closure`, which was only recently fixed (with the fix not yet
included in any stable release as of this writing). On a broken version, `-b`
will result in nothing being copied back at all. Fixed in CppNix by commit
[62adee899a](https://github.com/NixOS/nix/commit/62adee899a656516fc43c97782f102011e24e4ed)
and in Lix by commit
[eef57410d7](https://git.lix.systems/lix-project/lix/commit/eef57410d7c08beaf76b5254a8ffaee528d81335).
Use `nix-build-remotely.override { nix = …; }` to pass a fixed version.

### Use case: mostly build locally, occasionally remotely

In this case, you'll want both the local and remote store both to have signing
configured with mutual trust. In this case, you might want to use `-b` (but see
note above) so that any build deps get copied back for future local building.

### Use case: solely build remotely, but build deps stored locally

If you are entirely building remotely, it is sufficient only to enable signing
on the remote builder with a key trusted locally. To store build inputs locally
so they can be sent (which works because they're signed by the remote builder's
key) and reused for future builds, even after remote garbage collection, set
`keep-outputs = true` in your nix config and pass `-b` (see note above) when
building so that all built dependencies are copied back for future use.

If a store path _does_ end up being built locally, (perhaps due to IFD) and
later fails to send to the remote builder (due to not being signed), you can
use `-d -i` to build the derivation remotely, and then use `nix store copy-sigs`
copy the signature back (assuming a reproducible build).

### Use case: solely build remotely, remote binary cache for deps

Like the previous case, signing is only required on the remote machine. Instead
of using `-b` to copy build deps to the local machine, configure a
[post-build-hook](https://nix.dev/manual/nix/stable/advanced-topics/post-build-hook)
on the remote machine to copy built paths to a binary cache, and configure that
cache as a substituter on the remote machine. That way, build deps can be pulled
from the cache when needed for a future build, even after a remote garbage
collection.

In this case, you would pass `-n` when building remotely, since the deps are
already available for substitution on the remote machine.

If you want to store substited build inputs (including source files) in the
binary cache as well, you can do so with a hook like the following, which will
copy all transitive build inputs that exist in the store to the cache:

```
set -eufo pipefail
export IFS=' '
nix-store --query --requisites --include-outputs "$DRV_PATH" | \
    xargs nix --extra-experimental-features nix-command copy --to "file:///path/to/nix-cache"
```
