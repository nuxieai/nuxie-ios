"""Import the SDK's checksum-pinned runtime release; never compile runtime source."""

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
    local = ctx.getenv("NUXIE_RUNTIME_USE_LOCAL", "")
    if local not in ["", "1"]:
        fail("NUXIE_RUNTIME_USE_LOCAL must be unset or 1")
    if local == "1":
        staged = metadata_path.dirname.dirname.get_child(".artifacts/NuxieRuntime.xcframework")
        if not staged.exists:
            fail("Stage the local runtime with make stage-runtime-xcframework before opting in")
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

_runtime_repository = repository_rule(
    implementation = _runtime_repository_impl,
    attrs = {"metadata": attr.label(allow_single_file = True, mandatory = True)},
)

def _runtime_impl(ctx):
    artifacts = [tag for module in ctx.modules for tag in module.tags.artifact]
    if len(artifacts) != 1:
        fail("Exactly one immutable runtime artifact must be selected")
    _runtime_repository(name = "nuxie_runtime_release", metadata = artifacts[0].metadata)

runtime = module_extension(
    implementation = _runtime_impl,
    tag_classes = {"artifact": tag_class(attrs = {"metadata": attr.label(mandatory = True)})},
)
