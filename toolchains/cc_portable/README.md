# Portable C++ Toolchain for Bazel with Nixpkgs

This directory contains an implementation of a portable C++ toolchain that can be used with Bazel while leveraging Nixpkgs.

## Problem Statement

Standard C++ toolchains fetched from Nixpkgs via `rules_nixpkgs` have dependencies on specific Nix store paths. This creates portability issues when:

1. Using the toolchain on systems without the exact same Nix setup
2. Running in Bazel's sandboxed execution environments
3. Using remote execution or CI systems

The problem stems from binaries in Nixpkgs having hardcoded paths:
- On Linux: ELF binaries with hardcoded dynamic linker paths and RPATHs
- On macOS: Mach-O binaries with hardcoded library paths (@rpath references)

## Solution

This implementation creates a truly portable toolchain by:

1. **Bundling Dependencies**: All required runtime dependencies (shared libraries and dynamic linkers) are bundled alongside the toolchain executables.
2. **Patching Binaries**:
   - On Linux: Using `patchelf` to modify interpreter paths and RPATHs
   - On macOS: Using `install_name_tool` to modify library references to use @executable_path/@loader_path

This creates a self-contained toolchain that can be used in any environment, without requiring access to the original Nix store paths.

## Usage

In your WORKSPACE file:

```python
load("@rules_nixpkgs_cc_portable//:cc_portable.bzl", "nixpkgs_cc_portable_configure")

nixpkgs_cc_portable_configure(
    name = "local_config_cc_portable",
    repository = "@nixpkgs",
    # Optional: specific compiler via attribute path
    # attribute_path = "gcc11",
)
```

Then reference it in your .bazelrc file:

```
# Use the portable C++ toolchain by default
build --crosstool_top=@local_config_cc_portable//:toolchain
```

## Limitations

- May increase toolchain size due to bundling of dependencies
- One-time setup overhead for patching binaries 