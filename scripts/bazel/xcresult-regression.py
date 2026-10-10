"""Exercise the pinned runner against XCResult's sparse activity arrays."""

import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

roots = [root for root in Path(os.environ["TEST_SRCDIR"]).iterdir()
         if (root / "xctestrunner/test_runner/xcresult_util.py").is_file()]
if len(roots) != 1:
    raise RuntimeError("Expected one declared XCTest runner source")
sys.path.insert(0, str(roots[0]))
from xctestrunner.test_runner import xcresult_util


class XcresultAttachmentsTests(unittest.TestCase):
    def expose(self, activity):
        objects = {
            None: {"actions": {"_values": [{"_type": {"_name": "ActionRecord"},
                "actionResult": {"testsRef": {"id": {"_value": "tests"}}}}]}},
            "tests": {"summaries": {"_values": [{"testableSummaries": {"_values": [
                {"tests": {"_values": [{"testStatus": {"_value": "Expected Failure"},
                    "summaryRef": {"id": {"_value": "case"}}}]}}]}}]}},
            "case": {"identifier": {"_value": "Suite/testCase"}, **activity},
        }
        with patch.object(xcresult_util, "_GetResultBundleObject",
                          side_effect=lambda _path, bundle_id: objects[bundle_id]), \
                patch.object(xcresult_util, "_MakeXcresulttoolCommand", side_effect=lambda args: args), \
                patch.object(xcresult_util.subprocess, "check_call") as export:
            xcresult_util.ExposeXcresult("results.xcresult", "exports")
            return export.call_args_list

    def test_empty_activity_array_needs_no_exports(self):
        # XCResult omits _values for an empty Array, including expected failures.
        self.assertEqual(self.expose({"activitySummaries": {"_type": {"_name": "Array"}}}), [])

    def test_missing_activity_array_needs_no_exports(self):
        self.assertEqual(self.expose({}), [])

    def test_nonempty_activity_array_exports_its_attachment(self):
        attachment = {"filename": {"_value": "frame.png"},
                      "payloadRef": {"id": {"_value": "pixels"}}}
        with patch.object(xcresult_util.os.path, "exists", return_value=True):
            exports = self.expose({"activitySummaries": {"_values": [
                {"attachments": {"_values": [attachment]}}]}})
        self.assertEqual(len(exports), 1)
        self.assertEqual(exports[0].args[0], ["export", "--path", "results.xcresult",
            "--output-path", "exports/Attachments/Suite/testCase/frame.png",
            "--type", "file", "--id", "pixels"])


if __name__ == "__main__":
    unittest.main()
