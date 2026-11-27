"""Native Apple build targets and the existing source-based test fixture seam."""
load("@nuxie_machine//:staged.bzl", "MACHINE_STAGED")
load("@nuxie_runtime_release//:source-root.bzl", "SDK_SOURCE_ROOT")
load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("@rules_apple//apple/testing/default_runner:ios_xctestrun_runner.bzl", "ios_xctestrun_runner")
load("@rules_apple//apple/internal/aspects:swift_dynamic_framework_aspect.bzl", "SwiftDynamicFrameworkInfo")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:providers.bzl", "SwiftInfo")
load("@rules_swift//swift:swift_library.bzl", "swift_library")

def sdk_ios_test_runner(name, **kwargs):
    """Run XCTest on an isolated clone of an idle, prepared blank device."""
    if kwargs.pop("reuse_simulator", False):
        fail("SDK tests require an isolated simulator for each test action")
    kwargs.setdefault("testonly", True)
    ios_xctestrun_runner(
        name = name,
        reuse_simulator = False,
        create_simulator_action = "//scripts/bazel:simulator_create",
        clean_up_simulator_action = "//scripts/bazel:simulator_cleanup",
        **kwargs
    )

def _runtime_imports_aspect_impl(target, ctx):
    files = []
    if SwiftInfo in target:
        for module in target[SwiftInfo].direct_modules:
            if module.name == "NuxieRuntime" and module.swift:
                files.extend([module.swift.swiftmodule, module.swift.swiftdoc])
    transitive = []
    for name in ["deps", "artifact"]:
        dependencies = getattr(ctx.rule.attr, name, [])
        if type(dependencies) != "list":
            dependencies = [dependencies]
        for dependency in dependencies:
            if OutputGroupInfo in dependency and hasattr(dependency[OutputGroupInfo], "sdk_runtime_imports"):
                transitive.append(dependency[OutputGroupInfo].sdk_runtime_imports)
    return [OutputGroupInfo(sdk_runtime_imports = depset([file for file in files if file], transitive = transitive))]

# Framework linking needs the module, but can leave its documentation output
# unmaterialized. Publication retains both in the exact configured dependency.
sdk_runtime_imports_aspect = aspect(
    implementation = _runtime_imports_aspect_impl,
    attr_aspects = ["deps", "artifact"],
)

def _sdk_test_sources_impl(ctx):
    outputs = []
    sources = []
    for source in ctx.files.srcs:
        parts = source.short_path.split("/")
        output = ctx.actions.declare_file(ctx.label.name + "/" + "/".join(parts[:-1]) + "/mapped_" + parts[-1])
        outputs.append(output)
        sources.append([source.path, source.short_path, output.path])
    manifest = ctx.actions.declare_file(ctx.label.name + ".json")
    ctx.actions.write(manifest, json.encode({"root": SDK_SOURCE_ROOT, "sources": sources}))
    ctx.actions.run(
        executable = ctx.file._mapper,
        arguments = [manifest.path],
        inputs = ctx.files.srcs + [manifest],
        outputs = outputs,
        use_default_shell_env = True,
        mnemonic = "SDKTestSourcePaths",
    )
    return [DefaultInfo(files = depset(outputs))]

_sdk_test_sources = rule(
    implementation = _sdk_test_sources_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".swift"]),
        "_mapper": attr.label(default = "//scripts/bazel:map-test-sources.py", allow_single_file = True),
    },
)

def sdk_test_library(name, module_name, srcs, deps = [], defines = [], strict_concurrency = False, features = []):
    # The authored suites use #filePath to inspect source and signed fixtures.
    # A source-location directive retains the owning checkout contract without
    # changing authored tests or disabling Swift's hermetic compiler paths.
    _sdk_test_sources(name = name + "_file_paths", testonly = True, srcs = srcs)
    swift_library(
        name = name,
        testonly = True,
        module_name = module_name,
        package_name = "Nuxie",
        srcs = [":" + name + "_file_paths"],
        deps = deps,
        defines = defines,
        features = features,
        copts = ["-swift-version", "5"] + (["-strict-concurrency=complete"] if strict_concurrency else []),
    )

def _platform_transition_impl(_settings, attr):
    # rules_apple's legacy bundle transition derives the actual platform from
    # ios_multi_cpus, so the platform label alone does not select device code.
    if not attr.platform.name.startswith("ios_"):
        fail("SDK platform-bound artifacts require an iOS platform")
    return {
        "//command_line_option:platforms": [str(attr.platform)],
        "//command_line_option:apple_platforms": [str(attr.platform)],
        "//command_line_option:ios_multi_cpus": [attr.platform.name.removeprefix("ios_")],
    }

_platform_transition = transition(
    implementation = _platform_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms", "//command_line_option:apple_platforms", "//command_line_option:ios_multi_cpus"],
)

def _platform_artifact_impl(ctx):
    artifact = ctx.attr.artifact[0]
    return [artifact[DefaultInfo], artifact[AppleBundleInfo]]

sdk_platform_artifact = rule(
    implementation = _platform_artifact_impl,
    attrs = {
        "artifact": attr.label(mandatory = True, cfg = _platform_transition),
        "platform": attr.label(mandatory = True),
        "_allowlist_function_transition": attr.label(default = "@bazel_tools//tools/allowlists/function_transition_allowlist"),
    },
)

def _sdk_framework_module_impl(ctx):
    library = ctx.attr.deps[0]
    modules = library[SwiftInfo].direct_modules
    if len(modules) != 1 or not modules[0].swift:
        fail("SDK frameworks require one owning Swift module")
    module = modules[0]
    if not module.swift.generated_header:
        fail("The owning Swift module must generate its Objective-C header")
    modulemap = ctx.actions.declare_file(ctx.label.name + ".modulemap")
    ctx.actions.write(modulemap, 'framework module ' + module.name + ' {\n  header "' + module.name + '.h"\n  requires objc\n}\n')
    arch = ctx.fragments.apple.single_arch_cpu
    return [
        library[DefaultInfo],
        library[SwiftInfo],
        library[CcInfo],
        SwiftDynamicFrameworkInfo(
            module_name = module.name,
            generated_header = module.swift.generated_header,
            swiftdocs = {arch: module.swift.swiftdoc},
            swiftmodules = {arch: module.swift.swiftmodule},
            swiftinterfaces = {},
            modulemap = modulemap,
        ),
    ]

# rules_apple 4.5's Swift framework aspect selects the first transitive C header.
# Preserve native linkage while explicitly packaging the owning Swift header.
# This shim uses the provider consumed by the pinned dynamic-framework rules;
# it adds no compiler action and leaves the public Swift/Cc providers intact.
sdk_framework_module = rule(
    implementation = _sdk_framework_module_impl,
    fragments = ["apple"],
    attrs = {"deps": attr.label_list(mandatory = True, providers = [SwiftInfo, CcInfo])},
)

# The runtime host app takes the Nux machine's host screen only while the
# machine's tests-only library is staged. Then the host's module and app are
# test-only too, because the machine's module is. With nothing staged these
# give back exactly what they were given, and `None` for `testonly`, which
# Bazel reads as unset, so the graph is the graph without the machine. They
# live here, not in machine.bzl, because the root package loads this file and
# machine.bzl loads it in turn.
_MACHINE_HOST = "//Tests/ExperienceRuntimeHostApp/Machine:NuxieMachineHost"
_MACHINE_FIXTURES = "//Tests/NuxieMachineTests:NuxieMachineTests_fixtures"

def sdk_machine_host_deps(deps):
    """The runtime host app's module deps, with the machine's host screen when staged."""
    return deps + [_MACHINE_HOST] if MACHINE_STAGED else deps

def sdk_machine_host_resources(resources):
    """The runtime host app's resources, with Stillwater's fixture when staged."""
    return resources + [_MACHINE_FIXTURES] if MACHINE_STAGED else resources

def sdk_machine_host_testonly():
    """True when staged, otherwise unset."""
    return True if MACHINE_STAGED else None
