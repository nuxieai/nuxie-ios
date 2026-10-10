import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("sdk_frontend", Path(__file__).with_name("sdk.py"))
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)
plist_spec = importlib.util.spec_from_file_location("sdk_app_plist", Path(__file__).with_name("app-plist.py"))
app_plist = importlib.util.module_from_spec(plist_spec)
plist_spec.loader.exec_module(app_plist)
consumer_spec = importlib.util.spec_from_file_location("sdk_consumer", Path(__file__).with_name("check-consumer.py"))
consumer = importlib.util.module_from_spec(consumer_spec)
consumer_spec.loader.exec_module(consumer)


class ConsumerArtifactContractTests(unittest.TestCase):
    def test_cache_override_reaches_bazel_without_overriding_worktree_output_base(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(sdk, "ROOT", root), \
                    patch.dict("os.environ", {"NUXIE_BAZEL_BIN": "selected-bazel",
                                              "NUXIE_BAZEL_CACHE_DIR": str(root / "shared cache")}, clear=True):
                command = sdk.bazel_command()
            self.assertEqual(command, ["selected-bazel", "--nosystem_rc", "--nohome_rc",
                                       "--bazelrc=" + str(root / ".bazel-cache.local.bazelrc")])
            self.assertIn(str(root / "shared cache/actions"),
                          (root / ".bazel-cache.local.bazelrc").read_text())

    def test_owned_output_preserves_unrelated_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "ios-device/Release/Nuxie.framework/Nuxie"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"owned output")
            result = sdk.manifest(root, [], "c" * 40, False,
                                  {"release": "pin", "url": "url", "checksum": "hash"},
                                  {"buildSourceRevision": "b" * 40, "runtimeIdentity": "identity"})
            (root / "sdk-artifacts.json").write_text(json.dumps(result))
            sdk.check_owned_output(root)
            unrelated = root / "my-notes.txt"
            unrelated.write_text("retain this file")
            with self.assertRaises(ValueError):
                sdk.check_owned_output(root)
            self.assertEqual(unrelated.read_text(), "retain this file")
            self.assertEqual(binary.read_bytes(), b"owned output")

    def test_runtime_inputs_follow_exact_platform_slice_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime/NuxieRuntime.xcframework"
            libraries = []
            for identifier, target, variant, architectures in [
                ("device", "ios", "", ["arm64"]),
                ("simulator", "ios", "simulator", ["arm64", "x86_64"]),
                ("mac", "macos", "", ["arm64", "x86_64"]),
            ]:
                headers = runtime / identifier / "Headers"
                headers.mkdir(parents=True)
                (headers / "module.modulemap").write_text("module NuxieRuntimeC {}")
                (runtime / identifier / "runtime.a").write_bytes(b"archive")
                libraries.append({"LibraryIdentifier": identifier, "LibraryPath": "runtime.a",
                                  "HeadersPath": "Headers", "SupportedPlatform": target,
                                  "SupportedPlatformVariant": variant, "SupportedArchitectures": architectures})
            (runtime / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": libraries}))
            selected = sdk.runtime_dependencies(root, "ios-simulator", ["arm64", "x86_64"])
            self.assertEqual(selected["module"], "NuxieRuntimeC")
            self.assertEqual(selected["library"], "runtime/NuxieRuntime.xcframework/simulator/runtime.a")
            self.assertEqual(selected["moduleMap"], "runtime/NuxieRuntime.xcframework/simulator/Headers/module.modulemap")
            self.assertEqual(sdk.runtime_dependencies(root, "ios-device", ["arm64"])["library"],
                             "runtime/NuxieRuntime.xcframework/device/runtime.a")
            with self.assertRaises(ValueError):
                sdk.runtime_dependencies(root, "ios-device", ["x86_64"])
            (runtime / "simulator/Headers/module.modulemap").unlink()
            with self.assertRaises(ValueError):
                sdk.runtime_dependencies(root, "ios-simulator", ["arm64"])

    def test_manifest_retains_exact_release_and_source_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "ios-device/Release/Nuxie.framework/Nuxie"
            file.parent.mkdir(parents=True)
            file.write_bytes(b"native sdk binary")
            resource = root / "ios-device/Release/Nuxie_Nuxie.bundle/timezone-bundle.json"
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b"{}")
            artifact = {"release": "apple-runtime-v0.10.13", "url": "https://example.test/pinned.zip", "checksum": "a" * 64}
            artifact_set = {"buildSourceRevision": "b" * 40, "runtimeIdentity": "0.10.13@" + "b" * 40}
            result = sdk.manifest(root, [{"platform": "ios-device"}], "c" * 40, False, artifact, artifact_set, "d" * 64)
            self.assertEqual(result["schemaVersion"], 1)
            self.assertEqual(result["sdk"], "ios")
            self.assertEqual(result["runtime"], {
                **artifact, "sourceCommit": "b" * 40, "identity": "0.10.13@" + "b" * 40,
                "path": "runtime/NuxieRuntime.xcframework",
            })
            self.assertFalse(result["sourceDirty"])
            self.assertEqual(result["sourceContentDigest"], "d" * 64)
            self.assertEqual(result["artifacts"][0]["path"], "ios-device/Release/Nuxie.framework/Nuxie")
            self.assertEqual(result["artifacts"][0]["sha256"], hashlib.sha256(b"native sdk binary").hexdigest())
            self.assertEqual(result["artifacts"][0]["size"], 17)
            self.assertEqual(result["artifacts"][1]["kind"], "resource-file")
            self.assertEqual(result, sdk.manifest(root, [{"platform": "ios-device"}], "c" * 40, False, artifact, artifact_set, "d" * 64))

    def test_manifest_records_framework_symlink_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "Nuxie.framework/Versions/A/Nuxie"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"native binary")
            (root / "Nuxie.framework/Nuxie").symlink_to("Versions/A/Nuxie")
            result = sdk.manifest(root, [], "c" * 40, True,
                                  {"release": "pin", "url": "url", "checksum": "hash"},
                                  {"buildSourceRevision": "b" * 40, "runtimeIdentity": "identity"})
            self.assertEqual(result["symlinks"], [{"path": "Nuxie.framework/Nuxie", "target": "Versions/A/Nuxie"}])
            self.assertEqual(len(result["artifacts"]), 1)
            self.assertTrue(result["sourceDirty"])

    def test_owning_target_output_rejects_unrelated_frameworks(self):
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "NuxieSDK.zip"
            archive.write_bytes(b"archive")
            self.assertEqual(sdk.owning_archive([archive, Path(directory) / "TestHost.zip"], "NuxieSDK"), archive)
            with self.assertRaises(ValueError):
                sdk.owning_archive([Path(directory) / "TestHost.zip"], "NuxieSDK")
            with self.assertRaises(ValueError):
                sdk.owning_archive([archive, archive], "NuxieSDK")

    def test_framework_extraction_preserves_macos_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "sdk.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                bundle.writestr("Nuxie.framework/Versions/A/Nuxie", b"native")
                link = zipfile.ZipInfo("Nuxie.framework/Nuxie")
                link.external_attr = 0o120777 << 16
                bundle.writestr(link, "Versions/A/Nuxie")
            stage = root / "stage"
            stage.mkdir()
            framework = sdk.extract_framework(archive, stage)
            self.assertTrue((framework / "Nuxie").is_symlink())
            self.assertEqual((framework / "Nuxie").read_bytes(), b"native")

    def test_framework_archive_cannot_write_outside_stage(self):
        for entry, content, mode in [
            ("../escape", b"escape", 0o100644),
            ("Nuxie.framework/link", b"../../escape", 0o120777),
        ]:
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                archive = root / "sdk.zip"
                with zipfile.ZipFile(archive, "w") as bundle:
                    member = zipfile.ZipInfo(entry)
                    member.external_attr = mode << 16
                    bundle.writestr(member, content)
                stage = root / "stage"
                stage.mkdir()
                with self.assertRaises(ValueError):
                    sdk.extract_framework(archive, stage)
                self.assertFalse((root / "escape").exists())

    def test_distribution_rejects_local_runtime_before_any_bazel_action(self):
        args = argparse.Namespace(output="/tmp/unused-sdk-output", platform=["ios-device"], configuration="Release")
        with patch.dict("os.environ", {"NUXIE_RUNTIME_USE_LOCAL": "1"}), patch.object(sdk, "run") as run:
            with self.assertRaises(ValueError):
                sdk.prepare(args)
            run.assert_not_called()

    def test_distribution_rejects_dirty_source_before_any_bazel_action(self):
        with tempfile.TemporaryDirectory() as directory:
            args = argparse.Namespace(output=directory, platform=["ios-device"], configuration="Release")
            with patch.dict("os.environ", {"NUXIE_RUNTIME_USE_LOCAL": ""}), \
                    patch.object(sdk, "source_identity", return_value=("a" * 40, True, "b" * 64)), \
                    patch.object(sdk, "run") as run:
                with self.assertRaisesRegex(ValueError, "requires committed source"):
                    sdk.prepare(args)
                run.assert_not_called()

    def test_source_addressed_consumer_rejects_development_artifacts_before_swiftc(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "sdk-artifacts.json"
            manifest.write_text(json.dumps({"sourceDirty": True, "sourceContentDigest": "a" * 64}))
            with patch.object(consumer, "checked") as checked:
                with self.assertRaisesRegex(ValueError, "requires committed source"):
                    consumer.verify(manifest, "ios-device", "Release", "arm64")
                checked.assert_not_called()


class SourceIdentityTests(unittest.TestCase):
    def test_git_content_identity_covers_dirty_source_and_excludes_owned_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.run(["git", *args], cwd=root, check=True, text=True, capture_output=True).stdout.strip()
            git("init", "--quiet")
            source = root / "Swift source.swift"
            source.write_text("public let version = 1\n")
            git("add", ".")
            git("-c", "user.name=SDK Contract", "-c", "user.email=sdk-contract@example.test",
                "commit", "--quiet", "-m", "fixture")
            output = root / "products"
            with patch.object(sdk, "ROOT", root):
                initial = sdk.source_identity([output])
                self.assertEqual(initial[0], git("rev-parse", "HEAD"))
                self.assertFalse(initial[1])
                self.assertEqual(len(initial[2]), 64)
                output.mkdir()
                (output / "sdk-artifacts.json").write_text("generated output")
                self.assertEqual(sdk.source_identity([output]), initial)
                source.write_text("public let version = 2\n")
                modified = sdk.source_identity([output])
                self.assertEqual(modified[0], initial[0])
                self.assertTrue(modified[1])
                self.assertNotEqual(modified[2], initial[2])
                source.write_text("public let version = 1\n")
                self.assertEqual(sdk.source_identity([output]), initial)
                added = root / "untracked.swift\n"
                added.write_text("public let added = true\n")
                untracked = sdk.source_identity([output])
                self.assertTrue(untracked[1])
                self.assertNotEqual(untracked[2], initial[2])
                added.unlink()
                source.unlink()
                deleted = sdk.source_identity([output])
                self.assertTrue(deleted[1])
                self.assertNotEqual(deleted[2], initial[2])


class NativeCommandSelectionTests(unittest.TestCase):
    def command(self, argv):
        with patch("sys.argv", ["sdk.py", *argv]), patch.object(sdk, "bazel_command", return_value=["bazel"]), \
                patch.object(sdk, "run") as run, patch.object(sdk.platform, "machine", return_value="arm64"):
            sdk.main()
            return run.call_args.args[0]

    def test_macos_default_build_selects_macos_framework(self):
        command = self.command(["build", "--platform", "macos"])
        self.assertEqual(command[-1], "//:sdk_macos")
        self.assertIn("--platforms=@apple_support//platforms:macos_arm64", command)

    def test_release_device_build_uses_owning_sdk_target(self):
        command = self.command(["build", "--platform", "ios-device", "--configuration", "Release"])
        self.assertEqual(command[-1], "//:sdk")
        self.assertIn("--compilation_mode=opt", command)
        self.assertIn("--platforms=@apple_support//platforms:ios_arm64", command)
        self.assertIn("--ios_minimum_os=15.0", command)

    def test_hosted_input_suite_selects_its_hosted_test_rule(self):
        command = self.command(["test", "--suite", "hosted-input"])
        self.assertEqual(command[-1], "//:NuxieExperienceInputTests")
        self.assertEqual(command[1], "test")

    def test_focused_runtime_suite_preserves_all_three_native_classes(self):
        command = self.command(["test", "--suite", "native-runtime"])
        selector = next(arg for arg in command if arg.startswith("--test_filter="))
        self.assertEqual(selector, "--test_filter=NuxieSDKUnitTests/NuxieNativeRuntimeTests,"
                         "NuxieSDKUnitTests/ExperienceInteractiveScreenTests,"
                         "NuxieSDKUnitTests/ExperienceRuntimePresentationLoopTests")


class AuthoredAppMetadataTests(unittest.TestCase):
    def test_app_version_resolution_retains_native_settings_and_authored_metadata(self):
        source = sdk.ROOT / "Tests/ExperienceRuntimeHostApp/Sources/Info.plist"
        authored = plistlib.loads(source.read_bytes())
        resolved = plistlib.loads(app_plist.app_plist(source.read_bytes(), "0.1.0", "1"))
        self.assertEqual(resolved["CFBundleShortVersionString"], "0.1.0")
        self.assertEqual(resolved["CFBundleVersion"], "1")
        self.assertEqual(resolved["CFBundleExecutable"], "$(EXECUTABLE_NAME)")
        self.assertEqual(resolved["CFBundleIdentifier"], "$(PRODUCT_BUNDLE_IDENTIFIER)")
        for key in authored.keys() - {"CFBundleShortVersionString", "CFBundleVersion"}:
            self.assertEqual(resolved[key], authored[key])


if __name__ == "__main__":
    unittest.main()
