"""Exercise the vendored HTTP connection contract with synthetic TLS inputs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PREFIX = "NUXIE_BAZEL_REMOTE_CACHE_"
PROGRAM = """
import importlib.util, os, pathlib, sys
spec = importlib.util.spec_from_file_location("remote_cache", sys.argv[1])
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)
# Scope only the installed ownership boundary to this disposable fixture.
# Production has no environment or CLI override for these constants.
remote.tls_pin.TRUST_OWNER = os.getuid()
remote.tls_pin.TRUST_ROOT = pathlib.Path(sys.argv[3])
if sys.argv[2] == "fixture-create":
    remote.tls_pin.create(os.environ["NUXIE_BAZEL_REMOTE_CACHE_URL"],
        os.environ["NUXIE_BAZEL_REMOTE_CACHE_CA_FILE"], sys.argv[4],
        os.environ["NUXIE_BAZEL_REMOTE_CACHE_TLS_PIN_FILE"])
else:
    sys.argv = [sys.argv[1], sys.argv[2]]
    sys.exit(remote.main())
"""


class RemoteCacheConnectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.certificates = tempfile.TemporaryDirectory(prefix="sdk-cache-synthetic-certs-")
        cls.addClassCleanup(cls.certificates.cleanup)
        root = Path(cls.certificates.name).resolve()
        cls.issuer = root / "issuer.pem"
        cls.leaf = root / "leaf.pem"
        config = root / "openssl.cnf"
        config.write_text("""[req]
distinguished_name=dn
x509_extensions=ca
prompt=no
[dn]
CN=Synthetic SDK cache issuer
[ca]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
[leaf]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:cache.example
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
""")
        common = ["-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                  "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-config", str(config)]
        cls.openssl("req", "-new", "-x509", *common, "-keyout", str(root / "issuer.key"),
                    "-out", str(cls.issuer), "-days", "5")
        cls.openssl("req", "-new", *common, "-keyout", str(root / "leaf.key"),
                    "-out", str(root / "leaf.csr"), "-subj", "/CN=Synthetic SDK cache leaf")
        cls.openssl("x509", "-req", "-in", str(root / "leaf.csr"), "-CA", str(cls.issuer),
                    "-CAkey", str(root / "issuer.key"), "-CAcreateserial", "-out", str(cls.leaf),
                    "-days", "3", "-extfile", str(config), "-extensions", "leaf")

    @staticmethod
    def openssl(*arguments):
        subprocess.run(["/usr/bin/openssl", *arguments], check=True, capture_output=True,
                       timeout=5, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "OPENSSL_CONF": "/dev/null"})

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sdk-cache-connections-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root.chmod(0o700)
        leaf = self.root / "reviewed leaf.pem"
        issuer = self.root / "issuer.pem"
        leaf.write_bytes(self.leaf.read_bytes())
        issuer.write_bytes(self.issuer.read_bytes())
        leaf.chmod(0o644)
        issuer.chmod(0o644)
        credential = self.root / "credential.json"
        credential.write_text(json.dumps({"endpoint": "https://cache.example:8443",
                                         "username": "synthetic-reader", "password": "synthetic-secret"}))
        credential.chmod(0o600)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith(PREFIX)}
        self.environment.update({
            PREFIX + "MODE": "read", PREFIX + "URL": "https://cache.example:8443",
            PREFIX + "ELIGIBLE": "1", PREFIX + "DOMAIN": "sha256:" + "a" * 64,
            PREFIX + "CA_FILE": str(leaf), PREFIX + "TLS_PIN_FILE": str(self.root / "pin.json"),
            PREFIX + "CREDENTIAL_FILE": str(credential),
        })
        result = subprocess.run([sys.executable, "-I", "-B", "-c", PROGRAM,
                                 str(ROOT / "scripts/bazel/remote-cache.py"), "fixture-create",
                                 str(self.root), str(issuer)], env=self.environment, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def flags(self):
        return subprocess.run([sys.executable, "-I", "-B", "-c", PROGRAM,
                               str(ROOT / "scripts/bazel/remote-cache.py"), "flags", str(self.root)],
                              env=self.environment, capture_output=True, text=True, timeout=10)

    def assert_connection(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = result.stdout.splitlines()
        self.assertEqual([value for value in arguments if value.startswith("--remote_max_connections=")],
                         ["--remote_max_connections=1"])
        self.assertIn("--tls_certificate=" + self.environment[PREFIX + "CA_FILE"], arguments)
        self.assertNotIn("synthetic-secret", result.stdout + result.stderr)
        return arguments

    def test_read_and_write_use_one_canonical_http_connection(self):
        for mode in ("read", "write"):
            with self.subTest(mode=mode):
                self.environment[PREFIX + "MODE"] = mode
                arguments = self.assert_connection(self.flags())
                self.assertIn("--remote_upload_local_results=" + str(mode == "write").lower(), arguments)

    def test_absent_and_off_do_not_read_transport_or_add_connection_flags(self):
        self.environment = {key: value for key, value in self.environment.items() if not key.startswith(PREFIX)}
        result = self.flags()
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.environment.update({PREFIX + "MODE": "off", PREFIX + "CREDENTIAL_FILE": "/missing/private",
                                 PREFIX + "TLS_PIN_FILE": "/missing/public"})
        result = self.flags()
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "--remote_cache="))

    def test_sourced_shell_preserves_single_connection_and_spaced_leaf_path(self):
        environment = {**self.environment, "FIXTURE_PYTHON": sys.executable, "FIXTURE_PROGRAM": PROGRAM,
                       "FIXTURE_ROOT": str(self.root)}
        command = 'python3() { "$FIXTURE_PYTHON" -I -B -c "$FIXTURE_PROGRAM" "$@" "$FIXTURE_ROOT"; }; source "$1" && printf "%s\\n" "${NUXIE_BAZEL_REMOTE_ARGS[@]}"'
        result = subprocess.run(["/bin/bash", "-c", command, "fixture", str(ROOT / "scripts/bazel/remote-cache.sh")],
                                env=environment, capture_output=True, text=True, timeout=10)
        self.assert_connection(result)
        self.assertEqual(result.stdout, self.flags().stdout)


if __name__ == "__main__":
    unittest.main()
