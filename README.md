<!--
SPDX-FileCopyrightText: 2026 Erik Jensen <erikjensen@rkjnsn.net>
SPDX-License-Identifier: MIT
-->

# nix-utils

A collection of Nix utilities.

## Utilities

### `mkShell`

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

### `overrideImports`

Takes a source tree and an attribute set mapping Nix filenames to override
files. For each entry, the original file is renamed and replaced with a
wrapper that passes the value from importing the original as an argument to the
override file.

```nix
nix-utils.overrideImports sources.nixpkgs {
  "default.nix" = builtins.toFile "override.nix" ''
    orig: { overlays ? [], ... }@args:
    orig (args // { overlays = [ (final: prev: { /* ... */ }) ] ++ overlays; })
  '';
}
```

Multiple overrides to the same file stack: each override wraps the
previous one, with originals preserved as `*.orig.N.nix`.

Useful when you want override a certain entry point but keep the directory
structure intact. (E.g., so `import <nixpkgs> {}` includes a desired overlay,
but `import <nixpkgs/lib>` still works.)

### `fetch-nix-fod`

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

### `realize-nix-fod`

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

### `with-nix-sources`

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
