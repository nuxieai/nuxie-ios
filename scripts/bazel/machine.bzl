"""The Nux machine's module, its simulator suite, the runtime host app's
screen for it and its UI test, declared only when the machine's tests-only
library is staged at .artifacts/NuxMachine.xcframework.

With nothing staged these macros declare nothing, so the SDK's graph is the
graph without the machine. Nothing in the Nuxie product depends on them.
"""

load("@nuxie_machine//:staged.bzl", "MACHINE_STAGED")
load("@rules_apple//apple:ios.bzl", "ios_ui_test", "ios_unit_test")
load("@rules_apple//apple:resources.bzl", "apple_resource_group")
load("@rules_swift//swift:swift_library.bzl", "swift_library")
load("//scripts/bazel:sdk.bzl", "sdk_ios_test_runner", "sdk_test_library")

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
        visibility = [
            "//Tests/ExperienceRuntimeHostApp/Machine:__pkg__",
            "//Tests/NuxieMachineTests:__pkg__",
        ],
    )

def nuxie_machine_tests(name):
    """The simulator suite that drives the plan's compiled views with the machine."""
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
        # Package-relative: the bundle holds stillwater/<file>.
        strip_structured_resources_prefixes = ["Fixtures"],
        # The staged runtime host app bundles the same files.
        visibility = ["//:__pkg__"],
    )
    # The same hostless runner as the SDK's unit suites, which is private
    # to the root package.
    sdk_ios_test_runner(
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

def nuxie_machine_host(name):
    """The runtime host app's screen that starts a record and presents its sheet."""
    if not MACHINE_STAGED:
        return
    swift_library(
        name = name,
        testonly = True,
        module_name = name,
        package_name = "Nuxie",
        srcs = native.glob(["*.swift"]),
        copts = ["-swift-version", "5", "-strict-concurrency=complete"],
        deps = ["//Sources/NuxieMachine"],
        visibility = ["//:__pkg__"],
    )

def nuxie_machine_ui_tests(name):
    """The UI test that plays the paywall as a sheet in the runtime host app."""
    if not MACHINE_STAGED:
        return
    sdk_test_library(
        name = name + "_sources",
        module_name = name,
        srcs = native.glob(["*.swift"]),
    )
    # A simulator of its own for each run, removed after, as the machine
    # suite's runner does.
    sdk_ios_test_runner(
        name = name + "_runner",
        create_xcresult_bundle = True,
        reuse_simulator = False,
        xcodebuild_args = ["-parallel-testing-enabled", "NO"],
    )
    ios_ui_test(
        name = name,
        bundle_id = "com.nuxie.sdk.machine-uitests",
        minimum_os_version = "15.0",
        runner = ":" + name + "_runner",
        test_host = "//:NuxieExperienceRuntimeHostApp",
        deps = [":" + name + "_sources"],
        size = "large",
    )
