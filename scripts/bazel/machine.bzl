"""The Nux machine's module and its simulator suite, declared only when the
machine's tests-only library is staged at .artifacts/NuxMachine.xcframework.

With nothing staged these macros declare nothing, so the SDK's graph is the
graph without the machine. Nothing in the Nuxie product depends on them.
"""

load("@nuxie_machine//:staged.bzl", "MACHINE_STAGED")
load("@rules_apple//apple:ios.bzl", "ios_unit_test")
load("@rules_apple//apple:resources.bzl", "apple_resource_group")
load("@rules_apple//apple/testing/default_runner:ios_xctestrun_runner.bzl", "ios_xctestrun_runner")
load("@rules_swift//swift:swift_library.bzl", "swift_library")
load("//scripts/bazel:sdk.bzl", "sdk_test_library")

def nuxie_machine_module(name):
    """The Swift module over the machine's C interface and the engine."""
    if not MACHINE_STAGED:
        return
    swift_library(
        name = name,
        testonly = True,
        module_name = "NuxieMachine",
        package_name = "Nuxie",
        srcs = native.glob(["*.swift"]),
        copts = ["-swift-version", "5", "-strict-concurrency=complete"],
        deps = ["//:NuxieRuntime", "@nuxie_machine//:machine"],
        visibility = ["//Tests/NuxieMachineTests:__pkg__"],
    )

def nuxie_machine_tests(name):
    """The simulator suite that drives a published Screen with the machine."""
    if not MACHINE_STAGED:
        return
    sdk_test_library(
        name = name + "_sources",
        module_name = name,
        srcs = native.glob(["*.swift"]),
        strict_concurrency = True,
        deps = ["//:NuxieRuntime", "//Sources/NuxieMachine"],
    )
    apple_resource_group(
        name = name + "_fixtures",
        testonly = True,
        structured_resources = native.glob(["Fixtures/**"]),
        # Package-relative: the bundle holds stillwater-paywall/<file>.
        strip_structured_resources_prefixes = ["Fixtures"],
    )
    # The same hostless runner as the SDK's unit suites, which is private
    # to the root package.
    ios_xctestrun_runner(
        name = name + "_runner",
        create_xcresult_bundle = True,
        reuse_simulator = False,
        xcodebuild_args = ["-parallel-testing-enabled", "NO"],
    )
    ios_unit_test(
        name = name,
        bundle_id = "com.nuxie.sdk.machine-tests",
        minimum_os_version = "15.0",
        runner = ":" + name + "_runner",
        deps = [":" + name + "_sources"],
        resources = [":" + name + "_fixtures"],
        size = "large",
    )
