#!/usr/bin/env python3
"""Recovery guard tests: no real service, signals, credentials, or printers."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'deploy/printer-dashboard/watchdog/watchdog.py'
spec = importlib.util.spec_from_file_location('watchdog', path)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.patches = []
        for name, value in [('service_pid', 42), ('identity_matches', True),
                            ('health', False), ('evidence', Path('/tmp/diagnostic')),
                            ('log', None), ('save', None)]:
            p = patch.object(w, name, return_value=value)
            setattr(self, name, p.start()); self.patches.append(p)
        p = patch.object(w.os, 'kill'); self.kill = p.start(); self.patches.append(p)
        self.state = {'pid': 42, 'first_seen': 1000, 'failures': 0, 'last_restart': 0}

    def tearDown(self):
        for p in reversed(self.patches): p.stop()

    def test_only_three_persistent_failures_restart_existing_service(self):
        s = w.check(self.state, 2000)
        s = w.check(s, 2030)
        self.kill.assert_not_called()
        s = w.check(s, 2060)
        self.evidence.assert_called_once_with(42, 2060)
        self.save.assert_called_once()
        self.kill.assert_called_once_with(42, w.signal.SIGTERM)
        self.assertEqual(s['last_restart'], 2060)

    def test_health_resets_streak(self):
        self.health.return_value = True
        self.assertEqual(w.check(dict(self.state, failures=2), 2000)['failures'], 0)
        self.kill.assert_not_called()

    def test_new_pid_gets_grace_even_with_old_failure_streak(self):
        self.service_pid.return_value = 43
        s = w.check(dict(self.state, failures=9), 2000)
        self.assertEqual(s['pid'], 43)
        self.assertEqual(s['first_seen'], 2000)
        self.kill.assert_not_called()

    def test_startup_grace(self):
        w.check(dict(self.state, failures=9, first_seen=1950), 2000)
        self.kill.assert_not_called()

    def test_cooldown(self):
        w.check(dict(self.state, failures=9, last_restart=1900), 2000)
        self.kill.assert_not_called()

    def test_stopped_service_stays_stopped(self):
        self.service_pid.return_value = None
        w.check(dict(self.state, failures=9), 2000)
        self.health.assert_not_called(); self.kill.assert_not_called()

    def test_unrelated_process_never_signalled(self):
        self.identity_matches.return_value = False
        w.check(dict(self.state, failures=9), 2000)
        self.health.assert_not_called(); self.kill.assert_not_called()

    def test_pid_change_during_diagnostics_cancels_signal(self):
        self.service_pid.side_effect = [42, 43]
        w.check(dict(self.state, failures=9), 2000)
        self.kill.assert_not_called()

    def test_health_recovers_during_diagnostics(self):
        self.health.side_effect = [False, True]
        s = w.check(dict(self.state, failures=9), 2000)
        self.kill.assert_not_called(); self.assertEqual(s['failures'], 0)

    def test_identity_changes_during_diagnostics(self):
        self.identity_matches.side_effect = [True, False]
        w.check(dict(self.state, failures=9), 2000)
        self.kill.assert_not_called()

    def test_cannot_persist_restart_intent_means_no_signal(self):
        self.save.side_effect = OSError('read only')
        with self.assertRaises(OSError): w.check(dict(self.state, failures=9), 2000)
        self.kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
