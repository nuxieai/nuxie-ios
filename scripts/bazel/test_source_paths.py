import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("source_mapper", Path(__file__).with_name("map-test-sources.py"))
mapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mapper)


class AuthoredTestSourcePaths(unittest.TestCase):
    def test_swift_filepath_reads_own_checkout_with_hermetic_prefix_mapping(self):
        if not shutil.which("xcrun"):
            self.skipTest("The SDK's native source-path check requires Xcode")
        with tempfile.TemporaryDirectory(prefix="nuxie-source # ") as directory:
            root = Path(directory)
            checkout = root / "checkout"
            original = checkout / "Tests/Probe.swift"
            original.parent.mkdir(parents=True)
            (original.parent / "fixture.txt").write_text("own-worktree-fixture")
            source = ('import Foundation\n'
                      'let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixture.txt")\n'
                      'print(try String(contentsOf: fixture, encoding: .utf8))\n')
            original.write_text(source)
            execution_root = root / "isolated-execroot"
            execution_root.mkdir()
            output = execution_root / "mapped_Probe.swift"
            mapper.map_sources({"root": str(checkout), "sources": [[str(original), "Tests/Probe.swift", str(output)]]})
            self.assertTrue(output.read_text().endswith(source))
            binary = execution_root / "probe"
            subprocess.run(["xcrun", "swiftc", str(output), "-o", str(binary),
                            "-file-prefix-map", str(execution_root) + "=."], check=True, capture_output=True)
            self.assertEqual(subprocess.check_output([binary], text=True).strip(), "own-worktree-fixture")

    def test_source_outside_checkout_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "belong to the SDK"):
            mapper.map_sources({"root": "/checkout", "sources": [["unused", "../other/Tests.swift", "unused"]]})


if __name__ == "__main__":
    unittest.main()
