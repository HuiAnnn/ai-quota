#!/usr/bin/env python3
"""Deterministic checks; never read or change the user's keychain."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("local_signing", Path(__file__).with_name("local-signing.py"))
SIGNING = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIGNING)

SUBJECT = "AI Quota Local Signing"
BUNDLE_ID = "local.huian.codex-quota"
KEYCHAIN = str(Path.home() / "Library/Keychains/login.keychain-db")
CERTIFICATE = b"public certificate fixture"
FINGERPRINT = hashlib.sha1(CERTIFICATE).hexdigest().upper()
KEY_NOT_FOUND = "security: SecItemCopyMatching: The specified item could not be found in the keychain.\n"


class FakeCommands:
    def __init__(self, valid=True, existing=False, expired=False, fail_import=False):
        self.valid, self.existing, self.expired, self.fail_import = valid, existing, expired, fail_import
        self.calls, self.temp_dirs = [], []

    def __call__(self, args, check=True):
        self.calls.append(args)
        stdout, stderr, status = "", "", 0
        if args[1] == "find-identity":
            stdout = f'  1) {FINGERPRINT} "{SUBJECT}"\n 1 valid identities found\n' if self.valid else "0 valid identities found\n"
        elif args[1] == "find-certificate":
            # On this Mac, -a succeeds with empty output; one-item lookup returns 44.
            status = 0 if self.existing or "-a" in args else 44
        elif args[1] == "find-key":
            status = 0 if self.existing else 1
            stderr = "" if self.existing else KEY_NOT_FOUND
        elif args[1] == "genrsa":
            key = Path(args[args.index("-out") + 1])
            key.write_text("private fixture")
            self.temp_dirs.append(key.parent)
        elif args[1] == "req":
            Path(args[args.index("-out") + 1]).write_bytes(CERTIFICATE)
        elif args[1] == "x509" and "-out" in args:
            Path(args[args.index("-out") + 1]).write_bytes(CERTIFICATE)
        elif args[1] == "x509" and "-checkend" in args:
            status = 1 if self.expired else 0
        elif args[1] == "import":
            key = Path(args[2])
            if key.suffix == ".pem":
                assert key.stat().st_mode & 0o777 == 0o600
                assert key.parent.stat().st_mode & 0o777 == 0o700
            if self.fail_import:
                raise SIGNING.SigningError("本地签名设置未完成，请检查系统授权。")
        elif args[1] == "add-trusted-cert":
            self.valid = True
        if check and status:
            raise SIGNING.SigningError("签名命令失败。")
        return subprocess.CompletedProcess(args, status, stdout, stderr)


class StableIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name) / "Signing"
        self.commands = FakeCommands()
        self.manager = SIGNING.SigningManager(self.directory, self.commands, lambda _: None)

    def tearDown(self):
        self.temp.cleanup()

    def write_config(self, **overrides):
        self.directory.mkdir(exist_ok=True)
        config = dict(version=1, fingerprint=FINGERPRINT, keychain=KEYCHAIN, bundle_id=BUNDLE_ID)
        config.update(overrides)
        (self.directory / "identity.json").write_text(json.dumps(config))
        (self.directory / "certificate.cer").write_bytes(CERTIFICATE)

    def test_missing_config_refuses_without_generation(self):
        with self.assertRaises(SIGNING.SigningError):
            self.manager.identity()
        self.assertEqual(self.commands.calls, [])

    def test_valid_identity_returns_exact_pinned_fingerprint_without_mutation(self):
        self.write_config()
        self.assertEqual(self.manager.identity(), FINGERPRINT)
        self.assertFalse(any(args[1] in ("import", "genrsa", "add-trusted-cert") for args in self.commands.calls))

    def test_wrong_bundle_or_keychain_or_unknown_keys_refused(self):
        for changes in ({"bundle_id": "other"}, {"keychain": "/tmp/other"}, {"credential": "unrelated"}):
            with self.subTest(changes=changes):
                self.write_config(**changes)
                with self.assertRaises(SIGNING.SigningError):
                    self.manager.identity()
        self.assertEqual(self.commands.calls, [])

    def test_certificate_mismatch_refused_before_keychain_query(self):
        self.write_config(fingerprint="A" * 40)
        with self.assertRaises(SIGNING.SigningError):
            self.manager.identity()
        self.assertEqual(self.commands.calls, [])

    def test_invalid_metadata_types_refused_without_query(self):
        for changes in ({"version": True}, {"fingerprint": FINGERPRINT.lower()}, {"fingerprint": 1}):
            with self.subTest(changes=changes):
                self.write_config(**changes)
                with self.assertRaises(SIGNING.SigningError):
                    self.manager.identity()
        self.assertEqual(self.commands.calls, [])

    def test_symlink_certificate_refused(self):
        self.write_config()
        target = self.directory / "other.cer"
        (self.directory / "certificate.cer").rename(target)
        (self.directory / "certificate.cer").symlink_to(target)
        with self.assertRaises(SIGNING.SigningError):
            self.manager.identity()
        self.assertEqual(self.commands.calls, [])

    def test_dangling_signing_records_refuse_setup_without_generation(self):
        for name in ("identity.json", "pending.json", "certificate.cer"):
            with self.subTest(name=name):
                directory = self.directory / name
                directory.mkdir(parents=True)
                (directory / name).symlink_to(directory / "missing-target")
                commands = FakeCommands()
                manager = SIGNING.SigningManager(directory, commands, lambda _: None)
                with self.assertRaises(SIGNING.SigningError):
                    manager.setup()
                self.assertEqual(commands.calls, [])

    def test_command_errors_do_not_echo_arguments_or_stderr(self):
        with patch.object(SIGNING.subprocess, "run", side_effect=subprocess.CalledProcessError(
                1, ["command", "private-fixture"], stderr="private-fixture")):
            with self.assertRaises(SIGNING.SigningError) as caught:
                SIGNING.run_command(["command", "private-fixture"])
        self.assertNotIn("private-fixture", str(caught.exception))

    def test_missing_existing_identity_never_regenerated(self):
        self.write_config()
        self.commands.valid = False
        with self.assertRaises(SIGNING.SigningError):
            self.manager.setup()
        self.assertFalse(any(args[1] in ("genrsa", "import", "add-trusted-cert") for args in self.commands.calls))

    def test_expired_identity_never_regenerated(self):
        self.write_config()
        self.commands.expired = True
        with self.assertRaises(SIGNING.SigningError):
            self.manager.setup()
        self.assertFalse(any(args[1] in ("genrsa", "import", "add-trusted-cert") for args in self.commands.calls))

    def test_unknown_existing_subject_refuses_new_identity(self):
        self.commands.existing = True
        with self.assertRaises(SIGNING.SigningError):
            self.manager.setup()
        self.assertFalse(any(args[1] in ("genrsa", "import", "add-trusted-cert") for args in self.commands.calls))

    def test_interrupted_setup_is_not_restarted(self):
        self.directory.mkdir()
        (self.directory / "pending.json").write_text("{}")
        with self.assertRaises(SIGNING.SigningError):
            self.manager.setup()
        self.assertEqual(self.commands.calls, [])

    def test_setup_stores_only_metadata_and_cleans_private_temporary_files(self):
        self.assertEqual(self.manager.setup(), FINGERPRINT)
        data = json.loads((self.directory / "identity.json").read_text())
        self.assertEqual(set(data), {"version", "fingerprint", "keychain", "bundle_id"})
        self.assertEqual(set(path.name for path in self.directory.iterdir()), {"identity.json", "certificate.cer"})
        self.assertEqual(data["fingerprint"], FINGERPRINT)
        self.assertTrue(self.commands.temp_dirs)
        self.assertTrue(all(not path.exists() for path in self.commands.temp_dirs))
        imports = [args for args in self.commands.calls if args[1] == "import"]
        private_import = next(args for args in imports if "priv" in args)
        self.assertIn("-x", private_import)
        self.assertEqual(private_import[private_import.index("-T") + 1], "/usr/bin/codesign")
        self.assertFalse(any("-A" in args or "-P" in args or "set-key-partition-list" in args for args in self.commands.calls))
        self.assertTrue(all(args[0] in ("/usr/bin/openssl", "/usr/bin/security") for args in self.commands.calls))

    def test_only_user_code_signing_trust_is_added_when_needed(self):
        self.commands.valid = False
        self.assertEqual(self.manager.setup(), FINGERPRINT)
        trust = next(args for args in self.commands.calls if args[1] == "add-trusted-cert")
        self.assertEqual(trust[trust.index("-p") + 1], "codeSign")
        self.assertNotIn("-d", trust)
        self.assertNotIn("sudo", trust)

    def test_actual_empty_lookup_conventions_allow_first_setup(self):
        try:
            identity = self.manager.setup()
        except SIGNING.SigningError:
            identity = None
        self.assertEqual(identity, FINGERPRINT)

    def test_other_key_lookup_error_is_not_treated_as_absent(self):
        def failing_lookup(args, check=True):
            if args[1] == "find-key":
                return subprocess.CompletedProcess(args, 1, "", "security: User interaction is not allowed.\n")
            return self.commands(args, check)
        manager = SIGNING.SigningManager(self.directory, failing_lookup, lambda _: None)
        with self.assertRaises(SIGNING.SigningError):
            manager.setup()
        self.assertFalse(any(args[1] in ("genrsa", "import", "add-trusted-cert") for args in self.commands.calls))

    def test_command_locale_makes_public_metadata_errors_unambiguous(self):
        with patch.object(SIGNING.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")) as execute:
            SIGNING.run_command(["/usr/bin/security", "find-key"])
        self.assertEqual(execute.call_args.kwargs.get("env", {}).get("LC_ALL"), "C")

    def test_failed_import_keeps_pending_marker_and_erases_private_files(self):
        self.commands.fail_import = True
        with self.assertRaises(SIGNING.SigningError):
            self.manager.setup()
        self.assertTrue((self.directory / "pending.json").exists())
        self.assertFalse((self.directory / "identity.json").exists())
        self.assertTrue(all(not path.exists() for path in self.commands.temp_dirs))

    @unittest.skipUnless(Path("/usr/bin/openssl").exists(), "Requires macOS's bundled OpenSSL")
    def test_actual_openssl_generates_only_code_signing_certificate_without_keychain_access(self):
        def offline_commands(args, check=True):
            if args[0] == "/usr/bin/openssl":
                return SIGNING.run_command(args, check)
            if args[1] in ("find-certificate", "find-key"):
                return subprocess.CompletedProcess(args, 44, "", "")
            if args[1] == "find-identity":
                fingerprint = hashlib.sha1((self.directory / "certificate.cer").read_bytes()).hexdigest().upper()
                return subprocess.CompletedProcess(args, 0, f'1) {fingerprint} "{SUBJECT}"\n', "")
            self.assertEqual(args[1], "import")  # The OS keychain operations are all intercepted.
            return subprocess.CompletedProcess(args, 0, "", "")

        manager = SIGNING.SigningManager(self.directory, offline_commands, lambda _: None)
        manager.setup()
        public_text = SIGNING.run_command(["/usr/bin/openssl", "x509", "-inform", "DER", "-in",
                                          str(self.directory / "certificate.cer"), "-text", "-noout"]).stdout
        self.assertIn("Code Signing", public_text)
        self.assertIn("CA:FALSE", public_text)
        self.assertIn("2048 bit", public_text)
        self.assertNotIn("TLS Web", public_text)
        self.assertEqual(set(path.name for path in self.directory.iterdir()), {"identity.json", "certificate.cer"})


if __name__ == "__main__":
    unittest.main()
