"""Compare declared Bazel Swift ownership with the authored XcodeGen project."""

import ast
import fnmatch
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


def project_sources(target):
    project = (ROOT / "project.yml").read_text()
    section = re.search(r"^  " + re.escape(target) + r":\n(.*?)(?=^  \S|\Z)",
                        project, re.MULTILINE | re.DOTALL)
    if not section:
        raise ValueError("Missing original XcodeGen test target: " + target)
    sources = section[1].split("    sources:\n", 1)[1].split("    dependencies:\n", 1)[0]
    result = []
    for declaration in re.split(r"(?=^      - path: )", sources, flags=re.MULTILINE):
        match = re.match(r"      - path: ([^\n]+)", declaration)
        if not match:
            continue
        prefix = match[1].strip().strip('"')
        path = ROOT / prefix
        if path.is_file():
            if path.suffix == ".swift":
                result.append(prefix)
            continue
        if not path.is_dir():
            # Non-Swift resource folders are irrelevant to test source ownership.
            if prefix == "Tests/NuxieUnitTests":
                raise ValueError("The authored test directory is absent")
            continue
        includes = re.search(r"^        includes:\n((?:          [^\n]*\n)+)", declaration, re.MULTILINE)
        excludes = re.search(r"^        excludes:\n((?:          [^\n]*\n)+)", declaration, re.MULTILINE)
        include_patterns = re.findall(r"^          - (.+)$", includes[1], re.MULTILINE) if includes else ["*"]
        exclude_patterns = re.findall(r"^          - (.+)$", excludes[1], re.MULTILINE) if excludes else []
        for file in path.rglob("*.swift"):
            relative = file.relative_to(path).as_posix()
            if any(fnmatch.fnmatchcase(relative, value) for value in include_patterns) and not any(
                    fnmatch.fnmatchcase(relative, value) for value in exclude_patterns):
                result.append(file.relative_to(ROOT).as_posix())
    if not result:
        raise ValueError("The authored target owns no Swift sources")
    return result


def bazel_sources(target):
    graph = ast.parse((ROOT / "BUILD.bazel").read_text())
    calls = [node.value for node in graph.body if isinstance(node, ast.Expr)
             and isinstance(node.value, ast.Call)]
    selected = [call for call in calls if any(keyword.arg == "name"
                and isinstance(keyword.value, ast.Constant) and keyword.value.value == target
                for keyword in call.keywords)]
    if len(selected) != 1:
        raise ValueError("Expected one declared Bazel source target: " + target)
    attributes = {keyword.arg: keyword.value for keyword in selected[0].keywords}

    def evaluate(node, names=None):
        names = {} if names is None else names
        if isinstance(node, (ast.Constant, ast.List, ast.Tuple)):
            return ast.literal_eval(node)
        if isinstance(node, ast.Name):
            return names[node.id]
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
            return evaluate(node.left, names) + evaluate(node.right, names)
        if isinstance(node, ast.ListComp) and len(node.generators) == 1:
            generator = node.generators[0]
            if not isinstance(generator.target, ast.Name) or generator.ifs or generator.is_async:
                raise ValueError("Unsupported declared source comprehension")
            return [evaluate(node.elt, {**names, generator.target.id: value})
                    for value in evaluate(generator.iter, names)]
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "glob":
            patterns = evaluate(node.args[0], names)
            keywords = {keyword.arg: evaluate(keyword.value, names) for keyword in node.keywords}
            files = {file.relative_to(ROOT).as_posix() for pattern in patterns
                     for file in ROOT.glob(pattern) if file.is_file()}
            return sorted(file for file in files if not any(
                fnmatch.fnmatchcase(file, pattern) for pattern in keywords.get("exclude", [])))
        raise ValueError("Unsupported declared Bazel source expression")

    return evaluate(attributes["srcs"])


class AuthoredTestSourceMembershipTests(unittest.TestCase):
    def test_executor_sources_match_both_authored_platform_targets(self):
        expected = {"Tests/NuxieRuntimeExecutorTests/NuxieRuntimeExecutorTests.swift"}
        for source_target, bundle_target in [
            ("runtime_executor_test_sources", "NuxieRuntimeExecutorTests"),
            ("mac_runtime_executor_test_sources", "NuxieRuntimeExecutorMacTests"),
        ]:
            with self.subTest(target=bundle_target):
                self.assertEqual(set(bazel_sources(source_target)), expected)
                self.assertEqual(set(project_sources(bundle_target)), expected)
        self.assertTrue(expected.isdisjoint(bazel_sources("unit_test_sources")))
        self.assertTrue(expected.isdisjoint(bazel_sources("mac_unit_test_sources")))

    def test_hosted_sources_match_the_authored_xcode_target(self):
        actual = bazel_sources("experience_input_test_sources")
        self.assertEqual(len(actual), len(set(actual)), "Repeated Swift source in the hosted target")
        self.assertEqual(set(actual), set(project_sources("NuxieExperienceInputTests")))

    def test_unit_sources_preserve_the_authored_hosted_exclusions(self):
        actual = bazel_sources("unit_test_sources")
        self.assertEqual(len(actual), len(set(actual)), "Repeated Swift source in the unit target")
        self.assertEqual(set(actual), set(project_sources("NuxieSDKUnitTests")))


if __name__ == "__main__":
    unittest.main()
