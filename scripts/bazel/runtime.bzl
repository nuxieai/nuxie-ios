"""Import the staged runtime by default, or the explicit pinned release.

The same extension looks for the Nux machine's tests-only library at
.artifacts/NuxMachine.xcframework. Its repository always exists; it holds the
library and says MACHINE_STAGED = True only when one is staged, so the
machine's packages declare targets only then.
"""

_UNSTAGED_RUNTIME_MESSAGE = "No NuxieRuntime xcframework is staged at .artifacts/NuxieRuntime.xcframework. Stage one with `make stage-runtime-xcframework NUXIE_RUNTIME_XCFRAMEWORK=<path to a built NuxieRuntime.xcframework>`. NUXIE_RUNTIME_USE_LOCAL=0 selects the pinned release runtime instead."

_BUILD = """\
load("@rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
package(default_visibility = ["//visibility:public"])
apple_static_xcframework_import(
    name = "runtime",
    xcframework_imports = glob(["NuxieRuntime.xcframework/**"]),
    sdk_frameworks = [
        "CoreGraphics", "CoreText", "CoreVideo", "CryptoKit", "Foundation",
        "ImageIO", "Metal", "QuartzCore", "Security",
    ],
)
filegroup(name = "xcframework", srcs = glob(["NuxieRuntime.xcframework/**"]))
"""

def _runtime_repository_impl(ctx):
    metadata_path = ctx.path(ctx.attr.metadata)
    metadata = json.decode(ctx.read(metadata_path))
    local = ctx.getenv("NUXIE_RUNTIME_USE_LOCAL", "1")
    if local not in ["0", "1"]:
        fail("NUXIE_RUNTIME_USE_LOCAL must be unset, 1 or 0")
    if local == "1":
        staged = metadata_path.dirname.dirname.get_child(".artifacts/NuxieRuntime.xcframework")
        if not staged.exists:
            fail(_UNSTAGED_RUNTIME_MESSAGE)
        ctx.watch_tree(staged)
        ctx.symlink(staged, "NuxieRuntime.xcframework")
    else:
        ctx.download_and_extract(
            url = metadata["url"],
            sha256 = metadata["checksum"],
            type = "zip",
        )
        if not ctx.path("NuxieRuntime.xcframework/Info.plist").exists:
            fail("The pinned archive did not contain NuxieRuntime.xcframework")
    ctx.file("BUILD.bazel", _BUILD)
    ctx.file("source-root.bzl", "SDK_SOURCE_ROOT = " + repr(str(metadata_path.dirname.dirname)) + "\n")

_MACHINE_BUILD = """\
load("@rules_apple//apple:apple.bzl", "apple_static_xcframework_import")
package(default_visibility = ["//visibility:public"])
apple_static_xcframework_import(
    name = "machine",
    testonly = True,
    xcframework_imports = glob(["NuxMachine.xcframework/**"]),
)
"""

def _machine_repository_impl(ctx):
    staged = ctx.path(ctx.attr.metadata).dirname.dirname.get_child(".artifacts/NuxMachine.xcframework")
    # Watched whether or not it exists, so staging or removing the library
    # changes the graph on the next command.
    ctx.watch(staged)
    if staged.exists:
        ctx.watch_tree(staged)
        ctx.symlink(staged, "NuxMachine.xcframework")
        ctx.file("BUILD.bazel", _MACHINE_BUILD)
    else:
        ctx.file("BUILD.bazel", "")
    ctx.file("staged.bzl", "MACHINE_STAGED = " + repr(staged.exists) + "\n")

_machine_repository = repository_rule(
    implementation = _machine_repository_impl,
    attrs = {"metadata": attr.label(allow_single_file = True, mandatory = True)},
)

_runtime_repository = repository_rule(
    implementation = _runtime_repository_impl,
    attrs = {"metadata": attr.label(allow_single_file = True, mandatory = True)},
)

def _runtime_impl(ctx):
    artifacts = [tag for module in ctx.modules for tag in module.tags.artifact]
    if len(artifacts) != 1:
        fail("Exactly one immutable runtime artifact must be selected")
    _runtime_repository(name = "nuxie_runtime_release", metadata = artifacts[0].metadata)
    _machine_repository(name = "nuxie_machine", metadata = artifacts[0].metadata)

runtime = module_extension(
    implementation = _runtime_impl,
    tag_classes = {"artifact": tag_class(attrs = {"metadata": attr.label(mandatory = True)})},
)
