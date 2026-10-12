"""Select separately qualified read clients; SDK writers remain disabled."""
from pathlib import Path
import re

PROFILES = {'linux-native', 'linux-portable', 'macos-apple'}


def cache_environment(environment, profile):
    disabled = {'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'off'}
    mode = environment.get('NUXIE_CI_BAZEL_REMOTE_CACHE_MODE', 'off')
    if mode not in ('off', 'read', 'write'):
        raise ValueError('Remote cache mode must be off, read or write')
    if mode != 'read' or environment.get('NUXIE_CI_RUNNER_POLICY_VERSION') != '2':
        return disabled
    profiles = environment.get('NUXIE_CI_BAZEL_CACHE_PROFILES', '').split(',')
    if profiles == ['']:
        return disabled
    if any(name not in PROFILES for name in profiles):
        raise ValueError('Cache qualification must name explicit builder profiles')
    if profile not in profiles:
        return disabled
    if environment.get('NUXIE_BAZEL_REMOTE_CACHE_ELIGIBLE') != '1' or not re.fullmatch(
            r'sha256:[a-f0-9]{64}', environment.get('NUXIE_BAZEL_REMOTE_CACHE_DOMAIN', '')):
        return disabled
    controls = {}
    for suffix in ('URL', 'ELIGIBLE', 'DOMAIN', 'CA_FILE', 'TLS_PIN_FILE', 'CREDENTIAL_FILE'):
        name = 'NUXIE_BAZEL_REMOTE_CACHE_' + suffix
        value = environment.get(name)
        if not isinstance(value, str) or not value:
            return disabled
        if suffix.endswith('FILE') and (not Path(value).is_absolute() or len(value) > 4096 or
                                        any(ord(character) < 32 for character in value)):
            raise ValueError('Cache trust/credential paths must be bounded absolute paths')
        controls[name] = value
    return {**controls, 'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'read'}
