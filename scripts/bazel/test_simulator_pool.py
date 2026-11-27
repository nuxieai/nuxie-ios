import copy
import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from simulator_pool import MAX_SEEDS, Pool, device_in_use, process_identity, wait_quiet


class CoreSimulator:
    def __init__(self):
        self.runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'
        self.devices = {'personal': {'udid': 'personal', 'name': 'My iPhone', 'state': 'Booted', 'runtime': self.runtime, 'data': {'personal': True}}}
        self.calls = []; self.count = 0; self.fail_boot = False

    def __call__(self, args):
        self.calls.append(args)
        if args == ['list', '-j']:
            return json.dumps({'runtimes': [{'identifier': self.runtime, 'version': '27.0', 'buildversion': '27A1', 'isAvailable': True}],
                               'devices': {self.runtime: list(self.devices.values())}})
        if args[0] in ('create', 'clone'):
            self.count += 1; identifier = 'device-' + str(self.count)
            name = args[1] if args[0] == 'create' else args[2]
            data = {} if args[0] == 'create' else copy.deepcopy(self.devices[args[1]]['data'])
            self.devices[identifier] = {'udid': identifier, 'name': name, 'state': 'Shutdown', 'runtime': self.runtime, 'data': data}
            return identifier
        if args[0] == 'bootstatus':
            self.devices[args[1]]['state'] = 'Booted'
            if self.fail_boot:
                raise RuntimeError('simulator boot failed')
        elif args[0] == 'shutdown':
            self.devices[args[1]]['state'] = 'Shutdown'
        elif args[0] == 'delete':
            del self.devices[args[1]]
        else:
            raise AssertionError(args)
        return ''


class SimulatorPoolTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name); self.sim = CoreSimulator()
        self.owners = {101: 'first-birth', 102: 'second-birth'}; self.busy = set(); self.quiet = []
        self.pool = Pool(self.root, control=self.sim, identity=self.owners.get,
                         quiet=self.quiet.append, in_use=lambda d: d in self.busy, developer=lambda: 'xcode-a')

    def test_repeated_tests_clone_the_prepared_blank_and_keep_user_data_isolated(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.sim.devices[first]['data']['token'] = 'first-test-only'
        second = self.pool.create('27.0', 'iPhone 17 Pro', 102)
        self.assertNotEqual(first, second)
        self.assertEqual(self.sim.devices[second]['data'], {})
        self.assertEqual(len([c for c in self.sim.calls if c[0] == 'create']), 1)
        self.assertEqual(len([c for c in self.sim.calls if c[0] == 'clone']), 2)
        self.assertTrue(self.pool.cleanup(first, 101))
        self.assertNotIn(first, self.sim.devices)
        self.assertEqual(self.sim.devices[second]['state'], 'Booted')
        self.assertEqual(self.sim.devices['personal']['data'], {'personal': True})
        seeds = [d for d in self.sim.devices.values() if d['name'].startswith('NuxieSDKBlank-')]
        self.assertEqual([d['state'] for d in seeds], ['Shutdown'])
        self.assertEqual(len(self.quiet), 3)

    def test_cancelled_owner_is_reclaimed_without_touching_a_live_or_personal_device(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        second = self.pool.create('27.0', 'iPhone 17 Pro', 102)
        del self.owners[101]
        with self.pool.lock(): self.pool.reap()
        self.assertNotIn(first, self.sim.devices)
        self.assertIn(second, self.sim.devices); self.assertIn('personal', self.sim.devices)

    def test_pid_reuse_does_not_make_an_orphan_live_again(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.owners[101] = 'new-process-birth'
        with self.pool.lock(): self.pool.reap()
        self.assertNotIn(first, self.sim.devices)

    def test_orphan_with_xctest_still_running_is_preserved(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        del self.owners[101]; self.busy.add(first)
        with self.pool.lock(): self.pool.reap()
        self.assertIn(first, self.sim.devices)
        self.busy.clear()
        with self.pool.lock(): self.pool.reap()
        self.assertNotIn(first, self.sim.devices)

    def test_failed_boot_reaps_only_its_own_new_device(self):
        self.sim.fail_boot = True
        with self.assertRaisesRegex(RuntimeError, 'boot failed'):
            self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.assertEqual(list(self.sim.devices), ['personal'])
        self.assertEqual(list((self.root / 'seeds').iterdir()), [])

    def test_failed_clone_boot_does_not_destroy_the_prepared_seed(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.pool.cleanup(first, 101); self.sim.fail_boot = True
        with self.assertRaisesRegex(RuntimeError, 'boot failed'):
            self.pool.create('27.0', 'iPhone 17 Pro', 102)
        self.assertEqual(len(self.sim.devices), 2)
        self.assertEqual(list((self.root / 'leases').iterdir()), [])

    def test_another_owner_cannot_cleanup_the_device(self):
        first = self.pool.create('27.0', 'iPhone 17 Pro', 101)
        with self.assertRaisesRegex(ValueError, 'another test runner'):
            self.pool.cleanup(first, 102)
        self.assertIn(first, self.sim.devices)
        with self.assertRaisesRegex(ValueError, 'not owned'):
            self.pool.cleanup('personal', 101)

    def test_changed_xcode_or_viewport_has_a_distinct_prepared_blank(self):
        self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.pool.create('27.0', 'iPhone 16e', 101)
        self.pool.developer = lambda: 'xcode-b'
        self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.assertEqual(len([c for c in self.sim.calls if c[0] == 'create']), 3)

    def test_seed_cache_is_bounded_and_does_not_remove_test_clones(self):
        clones = [self.pool.create('27.0', 'viewport-' + str(n), 101) for n in range(MAX_SEEDS + 2)]
        self.assertEqual(len(list((self.root / 'seeds').glob('*.json'))), MAX_SEEDS)
        self.assertTrue(all(c in self.sim.devices for c in clones))
        self.assertIn('personal', self.sim.devices)

    def test_surviving_simulator_xctest_is_in_use_after_host_runner_ends(self):
        rows = {10: (1, 0, "launchd_sim /Users/levi/Library/Developer/CoreSimulator/Devices/owned/data/var/run/launchd_bootstrap.plist"),
                11: (10, 0, "/Xcode/usr/bin/xctest /bundle/Tests.xctest"),
                20: (1, 0, "launchd_sim /Users/levi/Library/Developer/CoreSimulator/Devices/personal/data/var/run/launchd_bootstrap.plist")}
        with patch('simulator_pool.process_sample', return_value=rows):
            self.assertTrue(device_in_use('owned'))
            self.assertFalse(device_in_use('personal'))
        rows[11] = (10, 0, "/bundle/UITests-Runner.app/UITests-Runner")
        with patch('simulator_pool.process_sample', return_value=rows):
            self.assertTrue(device_in_use('owned'))

    def test_in_flight_simulator_clone_is_preserved_without_a_recorded_udid(self):
        path = self.root / 'leases' / 'preparing.json'
        record = {'name': 'NuxieSDKTest-in-flight', 'runtime': self.sim.runtime,
                  'ownerPid': 999, 'ownerBirth': 'gone'}
        self.pool.write(path, record); self.busy.add(record['name'])
        with self.pool.lock(): self.pool.reap()
        self.assertTrue(path.exists())
        self.busy.clear()
        with self.pool.lock(): self.pool.reap()
        self.assertFalse(path.exists())

    def test_transient_process_timeout_restarts_the_quiet_window(self):
        clock = [0.0]; samples = [0]
        def sample(_):
            samples[0] += 1
            if samples[0] == 3:
                clock[0] += 6
                raise subprocess.TimeoutExpired('ps', 5)
            return {10: 1.0}
        with patch('simulator_pool.cpu_sample', side_effect=sample), \
                patch('simulator_pool.time.monotonic', side_effect=lambda: clock[0]), \
                patch('simulator_pool.time.sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            wait_quiet('owned', timeout=30)
        self.assertEqual(samples[0], 9)

    def test_cleanup_failure_keeps_the_original_preparation_error(self):
        self.sim.fail_boot = True
        with patch.object(self.pool, 'remove', side_effect=RuntimeError('observation unavailable')):
            with self.assertRaisesRegex(RuntimeError, 'simulator boot failed'):
                self.pool.create('27.0', 'iPhone 17 Pro', 101)
        self.assertEqual(len(list((self.root / 'seeds').glob('*.json'))), 1)

    def test_control_state_is_shared_across_isolated_test_home_directories(self):
        homes = self.root / 'account'; homes.mkdir()
        options = dict(control=self.sim, identity=self.owners.get, quiet=self.quiet.append,
                       in_use=lambda d: d in self.busy, developer=lambda: 'xcode-a')
        with patch('simulator_pool.pwd.getpwuid', return_value=SimpleNamespace(pw_dir=str(homes))):
            with patch.dict('os.environ', {'HOME': str(self.root / 'first-test-home')}):
                first = Pool(**options); identifier = first.create('27.0', 'iPhone 17 Pro', 101)
            with patch.dict('os.environ', {'HOME': str(self.root / 'second-test-home')}):
                second = Pool(**options)
                self.assertEqual(first.root, second.root)
                self.assertTrue(second.cleanup(identifier, 101))
        self.assertFalse((self.root / 'first-test-home').exists())
        self.assertFalse((self.root / 'second-test-home').exists())

    def test_live_owner_identity_is_independent_of_request_timezone(self):
        with patch.dict(os.environ, {'TZ': 'UTC'}):
            first = process_identity(os.getpid())
        with patch.dict(os.environ, {'TZ': 'Asia/Tokyo'}):
            second = process_identity(os.getpid())
        self.assertIsNotNone(first)
        self.assertEqual(first, second)

    def test_pool_and_receipts_cannot_be_symlinks(self):
        with tempfile.TemporaryDirectory() as target:
            link = self.root / 'linked'; link.symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'private owned'):
                Pool(link)
        self.pool.create('27.0', 'iPhone 17 Pro', 101)
        receipt = next((self.root / 'leases').glob('*.json'))
        external = self.root / 'external.json'; receipt.rename(external); receipt.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'private owned'):
            with self.pool.lock(): self.pool.reap()


if __name__ == '__main__':
    unittest.main()
