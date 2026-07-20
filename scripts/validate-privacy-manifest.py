#!/usr/bin/env python3

import plistlib
import sys


if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} /path/to/PrivacyInfo.xcprivacy")

manifest_path = sys.argv[1]
with open(manifest_path, "rb") as handle:
    privacy = plistlib.load(handle)

if privacy.get("NSPrivacyTracking") is not False:
    raise SystemExit("PrivacyInfo.xcprivacy must declare tracking=false")
if privacy.get("NSPrivacyTrackingDomains") != []:
    raise SystemExit("PrivacyInfo.xcprivacy must not declare tracking domains")

general_purposes = {
    "NSPrivacyCollectedDataTypePurposeAnalytics",
    "NSPrivacyCollectedDataTypePurposeProductPersonalization",
    "NSPrivacyCollectedDataTypePurposeAppFunctionality",
}
expected_collected = {
    "NSPrivacyCollectedDataTypeName": general_purposes,
    "NSPrivacyCollectedDataTypeEmailAddress": general_purposes,
    "NSPrivacyCollectedDataTypePhoneNumber": general_purposes,
    "NSPrivacyCollectedDataTypeUserID": general_purposes,
    "NSPrivacyCollectedDataTypeDeviceID": general_purposes,
    "NSPrivacyCollectedDataTypePurchaseHistory": general_purposes,
    "NSPrivacyCollectedDataTypeProductInteraction": general_purposes,
    "NSPrivacyCollectedDataTypeOtherUsageData": general_purposes,
    "NSPrivacyCollectedDataTypeOtherUserContent": general_purposes,
    "NSPrivacyCollectedDataTypeOtherDataTypes": general_purposes,
    "NSPrivacyCollectedDataTypeOtherDiagnosticData": {
        "NSPrivacyCollectedDataTypePurposeAnalytics",
        "NSPrivacyCollectedDataTypePurposeAppFunctionality",
    },
    "NSPrivacyCollectedDataTypePerformanceData": {
        "NSPrivacyCollectedDataTypePurposeAnalytics",
        "NSPrivacyCollectedDataTypePurposeAppFunctionality",
    },
}

collected = privacy.get("NSPrivacyCollectedDataTypes")
if not isinstance(collected, list):
    raise SystemExit("PrivacyInfo.xcprivacy is missing collected-data declarations")

actual_collected = {}
for declaration in collected:
    data_type = declaration.get("NSPrivacyCollectedDataType")
    if not isinstance(data_type, str) or not data_type:
        raise SystemExit("PrivacyInfo.xcprivacy contains an unnamed collected-data type")
    if data_type in actual_collected:
        raise SystemExit(f"PrivacyInfo.xcprivacy declares {data_type} more than once")
    if declaration.get("NSPrivacyCollectedDataTypeLinked") is not True:
        raise SystemExit(f"{data_type} must be declared linked to identity")
    if declaration.get("NSPrivacyCollectedDataTypeTracking") is not False:
        raise SystemExit(f"{data_type} must be declared tracking=false")
    purposes = declaration.get("NSPrivacyCollectedDataTypePurposes")
    if not isinstance(purposes, list):
        raise SystemExit(f"{data_type} is missing collection purposes")
    actual_collected[data_type] = set(purposes)

if set(actual_collected) != set(expected_collected):
    missing = sorted(set(expected_collected) - set(actual_collected))
    unexpected = sorted(set(actual_collected) - set(expected_collected))
    raise SystemExit(
        "PrivacyInfo.xcprivacy collected-data inventory differs from the SDK contract; "
        f"missing={missing}, unexpected={unexpected}"
    )

for data_type, expected_purposes in expected_collected.items():
    if actual_collected[data_type] != expected_purposes:
        raise SystemExit(
            f"{data_type} purposes differ from the SDK contract: "
            f"expected={sorted(expected_purposes)}, "
            f"actual={sorted(actual_collected[data_type])}"
        )

expected_accessed = {
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
}
accessed = privacy.get("NSPrivacyAccessedAPITypes")
if not isinstance(accessed, list):
    raise SystemExit("PrivacyInfo.xcprivacy is missing required-reason declarations")

actual_accessed = {}
for declaration in accessed:
    category = declaration.get("NSPrivacyAccessedAPIType")
    if not isinstance(category, str) or not category:
        raise SystemExit("PrivacyInfo.xcprivacy contains an unnamed API category")
    if category in actual_accessed:
        raise SystemExit(f"PrivacyInfo.xcprivacy declares {category} more than once")
    reasons = declaration.get("NSPrivacyAccessedAPITypeReasons")
    if not isinstance(reasons, list):
        raise SystemExit(f"{category} is missing required reasons")
    actual_accessed[category] = set(reasons)

if actual_accessed != expected_accessed:
    raise SystemExit(
        "PrivacyInfo.xcprivacy required-reason inventory differs from the SDK contract: "
        f"expected={expected_accessed}, actual={actual_accessed}"
    )

print(
    f"Validated {manifest_path}: tracking disabled, "
    f"{len(expected_collected)} collected-data types, "
    f"{len(expected_accessed)} required-reason API categories"
)
