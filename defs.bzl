"""Bazel rules for building Lean4 projects.

Similar to rules_rust, these rules provide:
- lean_library: Compile .lean files with automatic dependency analysis
  - Produces both static (.a) and shared (.so/.dylib) libraries like cc_library
  - linkstatic attribute controls which is preferred when consumed
- lean_binary: Link a Lean4 executable (native or interpreter mode)
- lean_test: Run Lean4 tests
- lean_module: Compile a single .lean file (for fine-grained deps)
"""

# Provider for Lean4 compilation artifacts
LeanInfo = provider(
    doc = "Information about compiled Lean4 modules",
    fields = {
        "olean_files": "depset of compiled .olean files",
        "ilean_files": "depset of .ilean files (interface files)",
        "c_files": "depset of generated C files",
        "o_files": "depset of compiled object files",
        "pic_o_files": "depset of position-independent object files (for shared libs)",
        "module_name": "string: the module name",
        "transitive_oleans": "depset of .olean files from transitive deps",
        "transitive_objects": "depset of .o files from transitive deps for linking",
        "transitive_pic_objects": "depset of .pic.o files from transitive deps for shared linking",
    },
)

def _lean_toolchain_impl(ctx):
    """Implementation of lean_toolchain rule."""
    # Derive include path from lean_headers files
    lean_include_path = ""
    if ctx.files.lean_headers:
        # Find the include directory by looking for lean.h
        for f in ctx.files.lean_headers:
            if f.path.endswith("lean/lean.h"):
                # Get the directory containing "lean/lean.h" -> parent of "lean"
                lean_include_path = f.dirname[:-5] if f.dirname.endswith("/lean") else f.dirname
                break

    return [platform_common.ToolchainInfo(
        lean = ctx.executable.lean,
        leanc = ctx.executable.leanc if ctx.attr.leanc else None,
        stdlib_oleans = ctx.files.stdlib_oleans,
        lib_lean_path = ctx.attr.lib_lean_path,
        lean_include_path = lean_include_path,
        lean_headers = ctx.files.lean_headers,
        runtime = ctx.attr.runtime,
        linker_flags = ctx.attr.linker_flags,
    )]

lean_toolchain = rule(
    implementation = _lean_toolchain_impl,
    attrs = {
        "lean": attr.label(
            doc = "The lean compiler executable",
            executable = True,
            cfg = "exec",
            mandatory = True,
        ),
        "leanc": attr.label(
            doc = "The leanc C wrapper (optional)",
            executable = True,
            cfg = "exec",
        ),
        "stdlib_oleans": attr.label_list(
            doc = "Standard library .olean files",
            allow_files = True,
        ),
        "lib_lean_path": attr.string(
            doc = "Path to lib/lean directory for LEAN_PATH",
            default = "",
        ),
        "lean_headers": attr.label_list(
            doc = "Lean header files for C compilation (lean.h, config.h, etc.)",
            allow_files = True,
        ),
        "runtime": attr.label(
            doc = "The lean runtime library",
        ),
        "linker_flags": attr.string_list(
            doc = "Platform-specific linker flags",
            default = [],
        ),
    },
    provides = [platform_common.ToolchainInfo],
)

def _lean_library_impl(ctx):
    """Implementation of lean_library rule.

    Uses 'lean --deps' for automatic dependency analysis and compiles files
    in topological order. Source files can be listed in any order.
    """
    toolchain = ctx.toolchains["//:toolchain_type"]
    lean = toolchain.lean
    leanc = getattr(toolchain, "leanc", None)

    stdlib_oleans = getattr(toolchain, "stdlib_oleans", [])
    lib_lean_path = getattr(toolchain, "lib_lean_path", "")

    # Collect transitive deps
    transitive_oleans = []
    transitive_objects = []
    transitive_pic_objects = []
    dep_olean_dirs = []
    for dep in ctx.attr.deps:
        if LeanInfo in dep:
            transitive_oleans.append(dep[LeanInfo].transitive_oleans)
            if hasattr(dep[LeanInfo], "transitive_objects"):
                transitive_objects.append(dep[LeanInfo].transitive_objects)
            if hasattr(dep[LeanInfo], "transitive_pic_objects"):
                transitive_pic_objects.append(dep[LeanInfo].transitive_pic_objects)
            for olean_file in dep[LeanInfo].olean_files.to_list():
                if olean_file.dirname not in dep_olean_dirs:
                    dep_olean_dirs.append(olean_file.dirname)

    module_name = ctx.attr.module_name or "".join([w.capitalize() for w in ctx.label.name.split("_")])
    output_base_dir = ctx.bin_dir.path + "/" + ctx.label.package

    lean_path_parts = [output_base_dir]
    if lib_lean_path:
        lean_path_parts.append(lib_lean_path)
    lean_path_parts.extend(dep_olean_dirs)
    lean_path_str = ":".join(lean_path_parts)

    # Optional prefix to strip from source paths
    strip_prefix = ctx.attr.strip_prefix

    # Declare outputs for all source files
    olean_files = []
    ilean_files = []
    c_files = []
    file_info = []  # List of (src, rel_path, olean, ilean, c_file)

    for src in ctx.files.srcs:
        if not src.basename.endswith(".lean"):
            fail("Source file must have .lean extension: " + src.path)

        if src.short_path.startswith(ctx.label.package + "/"):
            rel_path = src.short_path[len(ctx.label.package) + 1:]
        else:
            rel_path = src.basename

        # Strip prefix if specified
        if strip_prefix and rel_path.startswith(strip_prefix):
            rel_path = rel_path[len(strip_prefix):]

        rel_base = rel_path[:-5] if rel_path.endswith(".lean") else rel_path

        olean = ctx.actions.declare_file(rel_base + ".olean")
        ilean = ctx.actions.declare_file(rel_base + ".ilean")
        c_file = ctx.actions.declare_file(rel_base + ".c")

        olean_files.append(olean)
        ilean_files.append(ilean)
        c_files.append(c_file)
        file_info.append((src, rel_path, olean, ilean, c_file))

    # Build compile wrapper with automatic dependency analysis via lean --deps
    wrapper = ctx.actions.declare_file(ctx.label.name + "_compile.sh")

    # Generate file mapping for the script
    file_entries = []
    for src, rel_path, olean, ilean, c_file in file_info:
        mod_name = rel_path[:-5].replace("/", ".") if rel_path.endswith(".lean") else rel_path.replace("/", ".")
        file_entries.append("{src}|{rel}|{mod}|{olean}|{ilean}|{c}".format(
            src = src.path,
            rel = rel_path,
            mod = mod_name,
            olean = olean.path,
            ilean = ilean.path,
            c = c_file.path,
        ))

    wrapper_content = '''#!/bin/bash
set -e
export LEAN_PATH="{lean_path}"
LEAN="$1"

# File info: src_path|rel_path|module_name|olean|ilean|c_file
FILES='{file_entries}'

# Create directory structure and copy source files
echo "$FILES" | while IFS='|' read -r src rel mod olean ilean cfile; do
    [ -z "$src" ] && continue
    dir=$(dirname "$rel")
    [ "$dir" != "." ] && mkdir -p "$dir"
    cp -L "$src" "$rel"
done

# Python script handles dependency resolution and topological sort
OUTPUT_DIR=$(echo "$LEAN_PATH" | cut -d: -f1)

SORTED=$(python3 - "$LEAN" "$OUTPUT_DIR" "$FILES" << 'PYTHON_SCRIPT'
import sys
import subprocess
import os

lean_cmd = sys.argv[1]
output_dir = sys.argv[2]
files_str = sys.argv[3]

# Parse file entries
files = {{}}  # rel_path -> (olean, ilean, cfile)
for line in files_str.strip().split("\\n"):
    if not line.strip():
        continue
    parts = line.split("|")
    if len(parts) >= 6:
        src, rel, mod, olean, ilean, cfile = parts[:6]
        files[rel] = (olean, ilean, cfile)

# Get dependencies using lean --deps
deps = {{}}  # rel_path -> [dep_rel_paths]
for rel in files:
    deps[rel] = []
    try:
        result = subprocess.run(
            [lean_cmd, "--deps", rel],
            capture_output=True, text=True, timeout=30
        )
        for line in result.stdout.strip().split("\\n"):
            dep_olean = line.strip()
            if not dep_olean or not output_dir:
                continue
            # Check if this is an internal dependency
            if dep_olean.startswith(output_dir + "/"):
                # Convert olean path back to rel_path
                mod_olean = dep_olean[len(output_dir)+1:]
                # Find matching source file
                for other_rel in files:
                    other_base = other_rel[:-5] if other_rel.endswith(".lean") else other_rel
                    if mod_olean == other_base + ".olean":
                        deps[rel].append(other_rel)
                        break
    except Exception as e:
        print(f"Warning: failed to get deps for {{rel}}: {{e}}", file=sys.stderr)

# Topological sort
result = []
visited = set()
in_stack = set()

def visit(node):
    if node in visited:
        return
    if node in in_stack:
        print(f"Warning: cycle detected at {{node}}", file=sys.stderr)
        return
    in_stack.add(node)
    for dep in deps.get(node, []):
        visit(dep)
    in_stack.remove(node)
    visited.add(node)
    result.append(node)

for f in files:
    visit(f)

# Output sorted files with their output paths
for rel in result:
    olean, ilean, cfile = files[rel]
    print(f"{{rel}}|{{olean}}|{{ilean}}|{{cfile}}")
PYTHON_SCRIPT
)

# Compile files in topologically sorted order
echo "$SORTED" | while IFS='|' read -r rel olean ilean cfile; do
    [ -z "$rel" ] && continue
    echo "Compiling $rel..."
    "$LEAN" -o "$olean" -i "$ilean" -c "$cfile" "$rel"
done

echo "Compiled $(echo "$FILES" | grep -c '|' || echo 0) files"
'''.format(
        lean_path = lean_path_str,
        file_entries = "\n".join(file_entries),
    )

    ctx.actions.write(
        output = wrapper,
        content = wrapper_content,
        is_executable = True,
    )

    all_outputs = olean_files + ilean_files + c_files

    ctx.actions.run(
        outputs = all_outputs,
        inputs = depset(
            direct = ctx.files.srcs + [wrapper] + list(stdlib_oleans),
            transitive = transitive_oleans,
        ),
        executable = wrapper,
        arguments = [lean.path],
        mnemonic = "LeanCompile",
        progress_message = "Compiling Lean library %s (%d files)" % (ctx.label.name, len(ctx.files.srcs)),
        tools = [lean],
        execution_requirements = {"local": "1"},
    )

    # Compile C files to objects (in parallel)
    o_files = []
    pic_o_files = []  # Position-independent objects for shared lib
    lean_include_path = getattr(toolchain, "lean_include_path", "")
    lean_headers = getattr(toolchain, "lean_headers", [])
    linker_flags = getattr(toolchain, "linker_flags", [])

    # Always produce both static and shared libraries (like cc_library)
    # linkstatic controls which is preferred when consumed
    need_static = True
    need_shared = True
    need_pic = need_shared

    # Use Bazel CC toolchain for compiling C files (supports cross-compilation)
    cc_toolchain = ctx.attr._cc_toolchain[cc_common.CcToolchainInfo]
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )

    # Prepare include flags for lean.h
    include_flags = []
    if lean_include_path:
        include_flags.append("-isystem")
        include_flags.append(lean_include_path)
    else:
        # Debug: print warning if include path is not set
        print("WARNING: lean_include_path is not set in Lean toolchain")

    for src, rel_path, olean, ilean, c_file in file_info:
        rel_base = rel_path[:-5] if rel_path.endswith(".lean") else rel_path

        # Use cc_common.compile() for cross-compilation support
        (compilation_context, compilation_outputs) = cc_common.compile(
            name = ctx.label.name + "_" + rel_base.replace("/", "_"),
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            srcs = [c_file],
            private_hdrs = list(lean_headers),
            user_compile_flags = include_flags + ctx.attr.copts,
        )

        # Collect object files
        for obj in compilation_outputs.objects:
            o_files.append(obj)
        if need_pic:
            for pic_obj in compilation_outputs.pic_objects:
                pic_o_files.append(pic_obj)

    # Build output file list
    output_files = olean_files + c_files + o_files

    # Providers to return
    providers = [
        LeanInfo(
            olean_files = depset(olean_files),
            ilean_files = depset(ilean_files),
            c_files = depset(c_files),
            o_files = depset(o_files),
            pic_o_files = depset(pic_o_files),
            module_name = module_name,
            transitive_oleans = depset(direct = olean_files, transitive = transitive_oleans),
            transitive_objects = depset(direct = o_files, transitive = transitive_objects),
            transitive_pic_objects = depset(direct = pic_o_files, transitive = transitive_pic_objects),
        ),
    ]

    # Create static library if we have object files
    static_lib = None
    if need_static and o_files:
        static_lib = ctx.actions.declare_file("lib" + ctx.label.name + ".a")
        output_files.append(static_lib)

        # Collect all objects including from deps
        all_objects = o_files + depset(transitive = transitive_objects).to_list()

        # Get ar tool from toolchain
        ar_executable = cc_toolchain.ar_executable

        # Use ar to create static library
        # Note: on macOS, ar_executable may be libtool which needs different flags
        ar_args = ctx.actions.args()
        is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])
        if is_macos:
            # macOS libtool syntax: libtool -static -o output.a input.o...
            ar_args.add("-static")
            ar_args.add("-o")
            ar_args.add(static_lib)
            ar_args.add_all(all_objects)
        else:
            # Standard ar syntax: ar rcs output.a input.o...
            ar_args.add("rcs")
            ar_args.add(static_lib)
            ar_args.add_all(all_objects)

        ctx.actions.run(
            outputs = [static_lib],
            inputs = depset(all_objects, transitive = [cc_toolchain.all_files]),
            executable = ar_executable,
            arguments = [ar_args],
            mnemonic = "LeanArchive",
            progress_message = "Creating static library %s" % static_lib.basename,
        )

    # Create shared library if requested (requires leanc, skipped for cross-compilation)
    shared_lib = None
    if need_shared and leanc and pic_o_files:
        # Determine shared library extension and flags based on platform
        if ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo]):
            shared_ext = ".dylib"
            shared_flags = ["-dynamiclib"]
        else:
            shared_ext = ".so"
            shared_flags = ["-shared"]

        shared_lib = ctx.actions.declare_file("lib" + ctx.label.name + shared_ext)
        output_files.append(shared_lib)

        # Collect all PIC objects including from deps
        all_pic_objects = pic_o_files + depset(transitive = transitive_pic_objects).to_list()

        # Collect C libraries from cc_deps
        cc_libs = []
        for dep in ctx.attr.cc_deps:
            if CcInfo in dep:
                cc_info = dep[CcInfo]
                for linker_input in cc_info.linking_context.linker_inputs.to_list():
                    for lib in linker_input.libraries:
                        if lib.static_library:
                            cc_libs.append(lib.static_library)
                        elif lib.dynamic_library:
                            cc_libs.append(lib.dynamic_library)

        cc_lib_paths = [lib.path for lib in cc_libs]

        link_wrapper = ctx.actions.declare_file(ctx.label.name + "_link_shared.sh")
        link_wrapper_content = """#!/bin/bash
set -e
LEANC="$1"
OUTPUT="$2"
shift 2
"$LEANC" {shared_flags} -o "$OUTPUT" "$@" {cc_libs} {linker_flags} {user_linkopts}
""".format(
            shared_flags = " ".join(shared_flags),
            cc_libs = " ".join(cc_lib_paths),
            linker_flags = " ".join(linker_flags),
            user_linkopts = " ".join(ctx.attr.linkopts),
        )
        ctx.actions.write(output = link_wrapper, content = link_wrapper_content, is_executable = True)

        ctx.actions.run(
            outputs = [shared_lib],
            inputs = [link_wrapper] + all_pic_objects + cc_libs,
            executable = link_wrapper,
            arguments = [leanc.path, shared_lib.path] + [o.path for o in all_pic_objects],
            mnemonic = "LeanLinkShared",
            progress_message = "Linking shared library %s" % shared_lib.basename,
            tools = [leanc],
        )

    # Add CcInfo if we created a static or shared library
    if static_lib or shared_lib:
        libraries_to_link = []
        if static_lib:
            libraries_to_link.append(cc_common.create_library_to_link(
                actions = ctx.actions,
                static_library = static_lib,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
            ))
        if shared_lib:
            libraries_to_link.append(cc_common.create_library_to_link(
                actions = ctx.actions,
                dynamic_library = shared_lib,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
            ))

        cc_info = CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = ctx.label,
                        libraries = depset(libraries_to_link),
                    ),
                ]),
            ),
        )
        providers.append(cc_info)

    # Add DefaultInfo at the beginning
    providers.insert(0, DefaultInfo(files = depset(output_files)))

    return providers

lean_library = rule(
    implementation = _lean_library_impl,
    doc = """Compile a Lean4 library with automatic dependency analysis.

    Uses 'lean --deps' to determine compilation order automatically.
    Source files can be listed in any order - no manual ordering required.

    Like cc_library, this rule produces both static (.a) and shared (.so/.dylib)
    libraries. The linkstatic attribute controls which is preferred when consumed.
    Provides CcInfo for C/C++ interop.
    """,
    attrs = {
        "srcs": attr.label_list(
            doc = "Lean source files (order doesn't matter)",
            allow_files = [".lean"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Dependencies (other lean_library targets)",
            providers = [LeanInfo],
        ),
        "cc_deps": attr.label_list(
            doc = "C/C++ library dependencies for FFI (cc_library targets)",
        ),
        "module_name": attr.string(
            doc = "Module name (defaults to target name)",
        ),
        "strip_prefix": attr.string(
            doc = "Prefix to strip from source paths (e.g., 'lake/' for nested directories)",
            default = "",
        ),
        "copts": attr.string_list(
            doc = "Additional compiler options",
        ),
        "linkopts": attr.string_list(
            doc = "Additional linker options",
        ),
        "linkstatic": attr.bool(
            doc = "Prefer static linking when this library is consumed (like cc_library)",
            default = True,
        ),
        "_cc_toolchain": attr.label(
            default = "@bazel_tools//tools/cpp:current_cc_toolchain",
        ),
        "_macos_constraint": attr.label(
            default = "@platforms//os:macos",
        ),
    },
    toolchains = [
        "//:toolchain_type",
        "@bazel_tools//tools/cpp:toolchain_type",
    ],
    fragments = ["cpp"],
)

def _lean_binary_impl(ctx):
    """Implementation of lean_binary rule.

    Like cc_binary, this rule:
    - Compiles Lean sources to native code
    - Links against dependencies (both Lean and C/C++)
    - Uses linkstatic to control static vs dynamic linking
    """
    toolchain = ctx.toolchains["//:toolchain_type"]
    lean = toolchain.lean
    leanc = getattr(toolchain, "leanc", None)
    lib_lean_path = getattr(toolchain, "lib_lean_path", "")
    linker_flags = getattr(toolchain, "linker_flags", [])

    # Collect all oleans and objects from deps
    all_oleans = []
    all_objects = []
    for dep in ctx.attr.deps:
        if LeanInfo in dep:
            all_oleans.append(dep[LeanInfo].transitive_oleans)
            if hasattr(dep[LeanInfo], "transitive_objects"):
                all_objects.append(dep[LeanInfo].transitive_objects)

    # Collect C libraries from deps and cc_deps (like cc_binary)
    # Use linkstatic to determine static vs dynamic preference
    cc_libs = []
    prefer_static = ctx.attr.linkstatic

    # Helper to collect libraries from CcInfo
    def collect_cc_libs(cc_info):
        for linker_input in cc_info.linking_context.linker_inputs.to_list():
            for lib in linker_input.libraries:
                if prefer_static and lib.static_library:
                    cc_libs.append(lib.static_library)
                elif not prefer_static and lib.dynamic_library:
                    cc_libs.append(lib.dynamic_library)
                elif lib.static_library:
                    cc_libs.append(lib.static_library)
                elif lib.dynamic_library:
                    cc_libs.append(lib.dynamic_library)

    # Collect from deps (lean_library now provides CcInfo)
    for dep in ctx.attr.deps:
        if CcInfo in dep:
            collect_cc_libs(dep[CcInfo])

    # Collect from cc_deps (for pure C/C++ libraries)
    for dep in ctx.attr.cc_deps:
        if CcInfo in dep:
            collect_cc_libs(dep[CcInfo])

    # Output executable
    output = ctx.actions.declare_file(ctx.label.name)

    # Determine main source file
    if ctx.attr.main:
        main_src = ctx.file.main
    elif len(ctx.files.srcs) == 1:
        main_src = ctx.files.srcs[0]
    else:
        fail("Must specify 'main' attribute when multiple sources are provided")

    # Build LEAN_PATH from stdlib and dep olean directories
    lean_path_parts = []
    if lib_lean_path:
        lean_path_parts.append(lib_lean_path)
    for dep in ctx.attr.deps:
        if LeanInfo in dep:
            for olean_file in dep[LeanInfo].olean_files.to_list():
                if olean_file.dirname not in lean_path_parts:
                    lean_path_parts.append(olean_file.dirname)

    # If leanc is available, compile natively
    if leanc and not ctx.attr.interpreter_mode:
        # Compile main source to C
        main_basename = main_src.basename
        if not main_basename.endswith(".lean"):
            fail("Main source must have .lean extension")
        base_name = main_basename[:-5]

        main_c = ctx.actions.declare_file(base_name + "_main.c")
        main_olean = ctx.actions.declare_file(base_name + "_main.olean")
        main_ilean = ctx.actions.declare_file(base_name + "_main.ilean")

        lean_path_str = ":".join(lean_path_parts) if lean_path_parts else ""

        # Wrapper to compile main source
        compile_wrapper = ctx.actions.declare_file(base_name + "_main_compile.sh")
        compile_wrapper_content = """#!/bin/bash
set -e
export LEAN_PATH="{lean_path}"
cp -L "$1" "{src_basename}"
"$2" -o "$3" -i "$4" -c "$5" "{src_basename}"
""".format(
            src_basename = main_basename,
            lean_path = lean_path_str,
        )
        ctx.actions.write(
            output = compile_wrapper,
            content = compile_wrapper_content,
            is_executable = True,
        )

        stdlib_oleans = getattr(toolchain, "stdlib_oleans", [])
        ctx.actions.run(
            outputs = [main_olean, main_ilean, main_c],
            inputs = depset(
                direct = [main_src, compile_wrapper] + list(stdlib_oleans),
                transitive = all_oleans,
            ),
            executable = compile_wrapper,
            arguments = [main_src.path, lean.path, main_olean.path, main_ilean.path, main_c.path],
            mnemonic = "LeanCompileMain",
            progress_message = "Compiling Lean main %s" % main_src.short_path,
            tools = [lean],
        )

        # Compile main C to object
        main_o = ctx.actions.declare_file(base_name + "_main.o")
        cc_wrapper = ctx.actions.declare_file(base_name + "_main_cc.sh")
        cc_wrapper_content = """#!/bin/bash
set -e
"$1" -c -o "$2" "$3"
"""
        ctx.actions.write(
            output = cc_wrapper,
            content = cc_wrapper_content,
            is_executable = True,
        )
        ctx.actions.run(
            outputs = [main_o],
            inputs = [main_c, cc_wrapper],
            executable = cc_wrapper,
            arguments = [leanc.path, main_o.path, main_c.path],
            mnemonic = "LeanCompileMainC",
            progress_message = "Compiling C for Lean main %s" % main_src.short_path,
            tools = [leanc],
        )

        # Link all objects together using the C++ compiler (not leanc)
        # This avoids leanc's @rpath issues with libleanshared.dylib
        link_wrapper = ctx.actions.declare_file(base_name + "_link.sh")

        # Collect all object files
        dep_objects = depset(transitive = all_objects).to_list()
        all_obj_paths = [main_o.path] + [o.path for o in dep_objects]

        # Get the Lean runtime library from the toolchain via CcInfo
        runtime = getattr(toolchain, "runtime", None)
        lean_lib_dir = ""

        # Extract runtime libraries from CcInfo (includes cc_import shared libs)
        lean_dylib = None
        if runtime and CcInfo in runtime:
            cc_info = runtime[CcInfo]
            for linker_input in cc_info.linking_context.linker_inputs.to_list():
                for lib in linker_input.libraries:
                    if lib.dynamic_library:
                        lean_lib_dir = lib.dynamic_library.dirname
                        lean_dylib = lib.dynamic_library
                        # Add runtime library to cc_libs for linking
                        cc_libs.append(lib.dynamic_library)
                    elif lib.static_library:
                        cc_libs.append(lib.static_library)

        # Now compute cc_lib_paths after adding runtime
        cc_lib_paths = [lib.path for lib in cc_libs]

        # Determine platform-specific rpath flag
        # Use @loader_path for macOS to make the path relative to the binary
        is_macos = ctx.target_platform_has_constraint(ctx.attr._macos_constraint[platform_common.ConstraintValueInfo])
        if lean_lib_dir and lean_dylib:
            # Calculate relative path from binary to library
            # Binary is at: bazel-out/.../bin/magic_lean/magic_ffi_test
            # Library is at: bazel-out/.../bin/_solib_.../libleanshared.dylib
            # We need to go up from magic_lean to bin, then into _solib_...
            if is_macos:
                # @loader_path is where the binary is, go up to bin then to _solib_...
                rpath_flag = "-Wl,-rpath,@loader_path/../" + "/".join(lean_lib_dir.split("/")[-2:])
            else:
                rpath_flag = "-Wl,-rpath,$ORIGIN/../" + "/".join(lean_lib_dir.split("/")[-2:])
        else:
            rpath_flag = ""

        # Build link command using clang/cc instead of leanc
        # cc_libs already includes the Lean runtime (collected via CcInfo)
        link_wrapper_content = """#!/bin/bash
set -e
clang++ -o "$1" {objects} {cc_libs} {linker_flags} {rpath_flag} {user_linkopts}
""".format(
            objects = " ".join(all_obj_paths),
            cc_libs = " ".join(cc_lib_paths),
            linker_flags = " ".join(linker_flags),
            rpath_flag = rpath_flag,
            user_linkopts = " ".join(ctx.attr.linkopts),
        )
        ctx.actions.write(
            output = link_wrapper,
            content = link_wrapper_content,
            is_executable = True,
        )

        ctx.actions.run(
            outputs = [output],
            inputs = depset(
                direct = [main_o, link_wrapper] + cc_libs,
                transitive = all_objects,
            ),
            executable = link_wrapper,
            arguments = [output.path],
            mnemonic = "LeanLink",
            progress_message = "Linking Lean binary %s" % ctx.label.name,
        )
    else:
        # Fallback: interpreter mode using --run
        lean_path_str = ":".join(lean_path_parts) if lean_path_parts else ""

        run_wrapper = ctx.actions.declare_file(ctx.label.name + "_run.sh")
        run_wrapper_content = """#!/bin/bash
set -e
export LEAN_PATH="{lean_path}"
cp -L "$1" "{src_basename}"
"$2" --run "{src_basename}"
""".format(
            src_basename = main_src.basename,
            lean_path = lean_path_str,
        )
        ctx.actions.write(
            output = run_wrapper,
            content = run_wrapper_content,
            is_executable = True,
        )

        # Create a wrapper script as the executable
        script_content = """#!/bin/bash
LEAN_PATH="{lean_path}" "{lean}" --run "{src}"
""".format(
            lean_path = lean_path_str,
            lean = lean.short_path,
            src = main_src.short_path,
        )
        ctx.actions.write(
            output = output,
            content = script_content,
            is_executable = True,
        )

    runfiles = ctx.runfiles(
        files = [lean] + ctx.files.srcs + depset(transitive = all_oleans).to_list(),
    )

    return [
        DefaultInfo(
            executable = output,
            runfiles = runfiles,
        ),
    ]

lean_binary = rule(
    implementation = _lean_binary_impl,
    doc = """Compile and link a Lean4 executable.

    Like cc_binary, this rule:
    - Compiles Lean sources to native code by default
    - Links against dependencies (both lean_library and cc_library)
    - Uses linkstatic to control static vs dynamic linking preference
    """,
    attrs = {
        "srcs": attr.label_list(
            doc = "Lean source files",
            allow_files = [".lean"],
        ),
        "deps": attr.label_list(
            doc = "Dependencies (lean_library targets)",
            providers = [LeanInfo],
        ),
        "cc_deps": attr.label_list(
            doc = "C/C++ library dependencies for FFI (cc_library targets)",
        ),
        "main": attr.label(
            doc = "Main module file",
            allow_single_file = [".lean"],
        ),
        "copts": attr.string_list(
            doc = "Additional compiler options",
        ),
        "linkopts": attr.string_list(
            doc = "Additional linker options",
        ),
        "linkstatic": attr.bool(
            doc = "Link statically (like cc_binary). If True, prefer static libraries; if False, prefer dynamic.",
            default = True,
        ),
        "interpreter_mode": attr.bool(
            doc = "Run in interpreter mode (--run) instead of native compilation",
            default = False,
        ),
        "_macos_constraint": attr.label(
            default = "@platforms//os:macos",
        ),
    },
    executable = True,
    toolchains = ["//:toolchain_type"],
    fragments = ["cpp"],
)

def _lean_test_impl(ctx):
    """Implementation of lean_test rule."""
    # Tests are essentially binaries that we run
    toolchain = ctx.toolchains["//:toolchain_type"]
    lean = toolchain.lean

    # Create a test script that runs the lean file
    test_script = ctx.actions.declare_file(ctx.label.name + ".sh")

    # Collect all oleans from deps
    all_oleans = []
    olean_dirs = []
    for dep in ctx.attr.deps:
        if LeanInfo in dep:
            all_oleans.append(dep[LeanInfo].transitive_oleans)
            for olean_file in dep[LeanInfo].olean_files.to_list():
                if olean_file.dirname not in olean_dirs:
                    olean_dirs.append(olean_file.dirname)

    include_args = " ".join(["-I " + d for d in olean_dirs])

    if len(ctx.files.srcs) == 1:
        src = ctx.files.srcs[0]
    else:
        fail("lean_test must have exactly one source file")

    script_content = """#!/bin/bash
set -e
{lean} {includes} {src}
""".format(
        lean = lean.short_path,
        includes = include_args,
        src = src.short_path,
    )

    ctx.actions.write(
        output = test_script,
        content = script_content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(
        files = [lean, src] + depset(transitive = all_oleans).to_list(),
    )

    return [
        DefaultInfo(
            executable = test_script,
            runfiles = runfiles,
        ),
    ]

lean_test = rule(
    implementation = _lean_test_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "Lean test source files",
            allow_files = [".lean"],
            mandatory = True,
        ),
        "deps": attr.label_list(
            doc = "Dependencies (lean_library targets)",
            providers = [LeanInfo],
        ),
        "copts": attr.string_list(
            doc = "Additional compiler options",
        ),
    },
    test = True,
    toolchains = ["//:toolchain_type"],
)

# =============================================================================
# Stage0 Transition for building Lean stdlib from source
# =============================================================================

def _stage0_transition_impl(settings, attr):
    """Transition that forces stage0 toolchain for building Lean stdlib."""
    # Prepend stage0 toolchains to extra_toolchains so they take priority
    stage0_toolchains = [
        "//lean4/toolchain:stage0_toolchain_macos_arm64",
        "//lean4/toolchain:stage0_toolchain_macos_x86_64",
        "//lean4/toolchain:stage0_toolchain_linux_x86_64",
        "//lean4/toolchain:stage0_toolchain_linux_arm64",
    ]
    existing = settings["//command_line_option:extra_toolchains"]
    return {"//command_line_option:extra_toolchains": stage0_toolchains + existing}

_stage0_transition = transition(
    implementation = _stage0_transition_impl,
    inputs = ["//command_line_option:extra_toolchains"],
    outputs = ["//command_line_option:extra_toolchains"],
)

def _lean_stdlib_library_impl(ctx):
    """Wrapper that forwards providers from the transitioned lean_library."""
    # With transitions, ctx.attr.actual is a list
    actual = ctx.attr.actual[0]
    providers = [
        actual[DefaultInfo],
        actual[LeanInfo],
    ]
    if CcInfo in actual:
        providers.append(actual[CcInfo])
    return providers

_lean_stdlib_library = rule(
    implementation = _lean_stdlib_library_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            cfg = _stage0_transition,
            providers = [LeanInfo],
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    provides = [DefaultInfo, LeanInfo],
)

def lean_stdlib_library(name, **kwargs):
    """Macro for building Lean stdlib modules using stage0 toolchain.

    This ensures the Lean standard library is always built with the stage0
    bootstrap compiler, regardless of which toolchain is registered by default.

    Args:
        name: Target name
        **kwargs: Arguments passed to lean_library
    """
    # Create the actual lean_library with a private name
    impl_name = name + "_impl"
    lean_library(
        name = impl_name,
        visibility = ["//visibility:private"],
        **kwargs
    )

    # Create wrapper that applies stage0 transition
    _lean_stdlib_library(
        name = name,
        actual = ":" + impl_name,
    )
