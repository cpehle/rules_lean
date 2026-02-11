# rules_lean

Bazel rules for building Lean 4 projects.

## Setup

Add to your `MODULE.bazel`:

```python
bazel_dep(name = "rules_lean", version = "0.1.0")

lean = use_extension("@rules_lean//:extensions.bzl", "lean")
lean.release(name = "lean_release", version = "4.26.0")
use_repo(lean, "lean_release")

register_toolchains(
    "@rules_lean//toolchain:lean_toolchain_macos_arm64",
    "@rules_lean//toolchain:lean_toolchain_macos_x86_64",
    "@rules_lean//toolchain:lean_toolchain_linux_x86_64",
    "@rules_lean//toolchain:lean_toolchain_linux_arm64",
)
```

## Rules

### lean_library

Compiles Lean source files into a library with `.olean` files and static/shared libraries.

```python
load("@rules_lean//:defs.bzl", "lean_library")

lean_library(
    name = "mylib",
    srcs = ["Lib.lean"],
    module_name = "Lib",
)

# Multi-file library
lean_library(
    name = "myproject",
    srcs = [
        "MyProject/Base.lean",
        "MyProject/Utils.lean",
        "MyProject.lean",
    ],
    deps = [":mylib"],
)
```

**Attributes:**
| Name | Description |
|------|-------------|
| `srcs` | Lean source files (order doesn't matter - deps are auto-analyzed) |
| `deps` | Other `lean_library` or `lean_module` targets |
| `module_name` | Root module name (derived from target name if not specified) |
| `cc_deps` | C/C++ library dependencies for FFI |
| `strip_prefix` | Prefix to strip from source paths for module names |
| `linkstatic` | Prefer static linking when consumed (default: True) |

### lean_binary

Builds a native executable from Lean source files.

```python
load("@rules_lean//:defs.bzl", "lean_binary")

lean_binary(
    name = "hello",
    srcs = ["Hello.lean"],
)

# With library dependency
lean_binary(
    name = "myapp",
    srcs = ["Main.lean"],
    deps = [":mylib"],
)

# Interpreter mode (no native compilation)
lean_binary(
    name = "hello_interp",
    srcs = ["Hello.lean"],
    interpreter_mode = True,
)
```

**Attributes:**
| Name | Description |
|------|-------------|
| `srcs` | Lean source files |
| `deps` | Library dependencies |
| `cc_deps` | C/C++ dependencies for FFI |
| `interpreter_mode` | Run with `lean --run` instead of native compilation |
| `linkstatic` | Use static linking (default: True) |

### lean_test

Runs Lean files as tests.

```python
load("@rules_lean//:defs.bzl", "lean_test")

lean_test(
    name = "mytest",
    srcs = ["Test.lean"],
    deps = [":mylib"],
)
```

## FFI (Foreign Function Interface)

Call C functions from Lean using `@[extern]`:

```python
load("@rules_cc//cc:defs.bzl", "cc_library")

cc_library(
    name = "myffi",
    srcs = ["ffi.c"],
    hdrs = ["ffi.h"],
)

lean_binary(
    name = "ffi_example",
    srcs = ["FFIExample.lean"],
    cc_deps = [":myffi"],
)
```

```lean
-- FFIExample.lean
@[extern "c_add"]
opaque cAdd : UInt32 → UInt32 → UInt32

def main : IO Unit := do
  IO.println s!"Result: {cAdd 40 2}"
```

## Toolchains

### Downloaded Release (Default)

Uses pre-built Lean release with compiled stdlib:

```python
lean = use_extension("@rules_lean//:extensions.bzl", "lean")
lean.release(name = "lean_release", version = "4.26.0")
use_repo(lean, "lean_release")

register_toolchains("@rules_lean//toolchain:lean_toolchain_macos_arm64")
```

### Custom Toolchain

Define a custom toolchain:

```python
load("@rules_lean//:defs.bzl", "lean_toolchain")

lean_toolchain(
    name = "my_toolchain_impl",
    lean = "@my_lean//:lean",
    leanc = "@my_lean//:leanc",
    stdlib_oleans = ["@my_lean//:stdlib_oleans"],
    lib_lean = "@my_lean//:lib_lean",
    runtime = "@my_lean//:leanrt",
    linker_flags = select({
        "@platforms//os:macos": ["-lc++"],
        "@platforms//os:linux": ["-lstdc++", "-lpthread", "-ldl", "-lm"],
    }),
)

toolchain(
    name = "my_toolchain",
    toolchain = ":my_toolchain_impl",
    toolchain_type = "@rules_lean//:toolchain_type",
)
```

## Building Lean Stdlib from Source

Use `lean_stdlib_library` which automatically applies the stage0 toolchain:

```python
load("@rules_lean//:defs.bzl", "lean_stdlib_library")

lean_stdlib_library(
    name = "Init",
    srcs = glob(["Init/**/*.lean"]) + ["Init.lean"],
    module_name = "Init",
)
```

## Examples

See `examples/` directory for working examples:

```bash
bazel build //examples:hello
bazel run //examples:hello

bazel build //examples:use_chain    # Chained library deps
bazel build //examples:ffi_test     # FFI example
bazel test //examples:hello_test    # Test example
```
