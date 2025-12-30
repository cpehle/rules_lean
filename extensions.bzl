"""Lean toolchain repository rules for downloading pre-built releases."""

# URLs for Lean4 releases
_LEAN_RELEASES = {
    "4.26.0": {
        "darwin_aarch64": {
            "url": "https://github.com/leanprover/lean4/releases/download/v4.26.0/lean-4.26.0-darwin_aarch64.tar.zst",
            "sha256": "",  # TODO: Add sha256
            "strip_prefix": "lean-4.26.0-darwin_aarch64",
        },
        "darwin_x86_64": {
            "url": "https://github.com/leanprover/lean4/releases/download/v4.26.0/lean-4.26.0-darwin_x86_64.tar.zst",
            "sha256": "",
            "strip_prefix": "lean-4.26.0-darwin_x86_64",
        },
        "linux_x86_64": {
            "url": "https://github.com/leanprover/lean4/releases/download/v4.26.0/lean-4.26.0-linux.tar.zst",
            "sha256": "",
            "strip_prefix": "lean-4.26.0-linux",
        },
        "linux_aarch64": {
            "url": "https://github.com/leanprover/lean4/releases/download/v4.26.0/lean-4.26.0-linux_aarch64.tar.zst",
            "sha256": "",
            "strip_prefix": "lean-4.26.0-linux_aarch64",
        },
    },
}

def _get_platform_info(repository_ctx):
    """Determine the current platform."""
    os_name = repository_ctx.os.name.lower()
    if "mac" in os_name or "darwin" in os_name:
        os_type = "darwin"
    elif "linux" in os_name:
        os_type = "linux"
    else:
        fail("Unsupported OS: " + os_name)

    # Detect architecture
    arch_result = repository_ctx.execute(["uname", "-m"])
    arch = arch_result.stdout.strip()
    if arch == "arm64" or arch == "aarch64":
        cpu = "aarch64"
    elif arch == "x86_64":
        cpu = "x86_64"
    else:
        fail("Unsupported architecture: " + arch)

    return os_type + "_" + cpu

def _lean_release_impl(repository_ctx):
    """Download and extract a Lean release."""
    version = repository_ctx.attr.version
    platform = _get_platform_info(repository_ctx)

    if version not in _LEAN_RELEASES:
        fail("Unknown Lean version: " + version)

    release_info = _LEAN_RELEASES[version]
    if platform not in release_info:
        fail("No release for platform: " + platform)

    info = release_info[platform]

    # Download and extract
    download_kwargs = {
        "url": info["url"],
        "stripPrefix": info["strip_prefix"],
    }
    if info["sha256"]:
        download_kwargs["sha256"] = info["sha256"]

    repository_ctx.download_and_extract(**download_kwargs)

    # Create BUILD file exposing the toolchain components
    repository_ctx.file("BUILD.bazel", """
load("@rules_cc//cc:defs.bzl", "cc_import")

package(default_visibility = ["//visibility:public"])

# Export the lean compiler binary
exports_files(["bin/lean", "bin/leanc", "bin/lake"])

sh_binary(
    name = "lean",
    srcs = ["bin/lean"],
)

sh_binary(
    name = "leanc",
    srcs = ["bin/leanc"],
)

sh_binary(
    name = "lake",
    srcs = ["bin/lake"],
)

# Export all stdlib olean files
filegroup(
    name = "stdlib_oleans",
    srcs = glob(["lib/lean/**/*.olean"]),
)

# Export the lib/lean directory for LEAN_PATH
filegroup(
    name = "lib_lean",
    srcs = glob(["lib/lean/**"]),
)

# Runtime library (may not exist on all platforms)
cc_library(
    name = "leanrt",
    srcs = glob(["lib/lean/libleanrt.*", "lib/lean/libleanshared.*"], allow_empty = True),
    hdrs = glob(["include/**/*.h"], allow_empty = True),
    includes = ["include"],
)
""")

lean_release = repository_rule(
    implementation = _lean_release_impl,
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "Lean version to download (e.g., '4.26.0')",
        ),
    },
    doc = "Downloads a pre-built Lean release.",
)
