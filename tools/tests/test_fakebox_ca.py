"""Unit tests for tools/fakebox/ca.py (#547, docs/fakebox-design.md §5): the fake sync box's CA and
leaves have the real box's shape (docs/syncbox-architecture-research.md §2.2), chain to the fake CA and
never to the driver's pinned root-hsb, reuse what is right and replace what is not, and keep their keys
private. Every file goes under a temporary directory; HOME is pointed there for the default base.

Run: python3 -m unittest discover -s tools/tests -p test_fakebox_ca.py -v
"""

import os
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
sys.path.insert(0, TOOLS)

from fakebox import ca  # noqa: E402

HSB_CA = os.path.join(ROOT, "src", "hue_syncbox", "certs", "hsb_ca.pem")
BOX = "0A1B2C3D4E5F"
OTHER_BOX = "0A1B2C3D4E60"


def openssl(*args):
    return subprocess.run(["openssl", *args], capture_output=True, text=True, check=False)


def text_of(cert):
    proc = openssl("x509", "-in", cert, "-noout", "-text")
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def subject(cert, which="-subject"):
    out = openssl("x509", "-in", cert, "-noout", which, "-nameopt", "RFC2253").stdout.strip()
    return out.split("=", 1)[1]


def verify(ca_file, cert):
    return openssl("verify", "-CAfile", ca_file, "-purpose", "sslserver", cert)


def read(path):
    with open(path, "rb") as handle:
        return handle.read()


def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def handshake(cert, key, cafile):
    """A TLS handshake in memory: a server with cert/key, a client trusting only cafile and checking no
    host name (the driver's ssl_verify_host = false). The server's certificate as the client saw it."""
    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(cert, key)
    client_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    client_ctx.check_hostname = False
    client_ctx.verify_mode = ssl.CERT_REQUIRED
    client_ctx.load_verify_locations(cafile)
    c_in, c_out, s_in, s_out = ssl.MemoryBIO(), ssl.MemoryBIO(), ssl.MemoryBIO(), ssl.MemoryBIO()
    client = client_ctx.wrap_bio(c_in, c_out, server_side=False)
    server = server_ctx.wrap_bio(s_in, s_out, server_side=True)
    done = {"client": False, "server": False}
    for _ in range(20):
        for name, end in (("client", client), ("server", server)):
            if done[name]:
                continue
            try:
                end.do_handshake()
                done[name] = True
            except ssl.SSLWantReadError:
                pass
        s_in.write(c_out.read())
        c_in.write(s_out.read())
        if all(done.values()):
            return client.getpeercert()
    raise AssertionError("the handshake did not finish")


class Case(unittest.TestCase):
    def setUp(self):
        if not shutil.which("openssl"):
            self.skipTest("the openssl command is not installed")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = os.path.join(self.tmp.name, "fakebox")


class CATest(Case):
    def test_the_ca_is_a_self_signed_p256_ca_with_its_name(self):
        cert = ca.ensure_ca(self.base)
        self.assertEqual(cert, os.path.join(self.base, "ca.pem"))
        self.assertEqual(subject(cert), "CN=c4-hue fake sync box CA")
        self.assertEqual(subject(cert, "-issuer"), "CN=c4-hue fake sync box CA")
        text = text_of(cert)
        self.assertIn("NIST CURVE: P-256", text)
        self.assertRegex(text, r"Basic Constraints: critical\s+CA:TRUE")
        self.assertRegex(text, r"Key Usage: critical\s+Certificate Sign")
        self.assertEqual(openssl("verify", "-CAfile", cert, cert).returncode, 0)

    def test_files_are_private(self):
        ca.ensure_box_cert(BOX, "HSB2", self.base)
        self.assertEqual(mode(self.base), 0o700)
        self.assertEqual(mode(os.path.join(self.base, "boxes")), 0o700)
        self.assertEqual(mode(os.path.join(self.base, "ca.key")), 0o600)
        self.assertEqual(mode(os.path.join(self.base, "boxes", BOX + ".key")), 0o600)
        # Nothing left behind by the atomic writes or the openssl work directories.
        leftovers = [n for n in os.listdir(self.base) + os.listdir(os.path.join(self.base, "boxes")) if "tmp" in n]
        self.assertEqual(leftovers, [])
        self.assertFalse([n for n in os.listdir(self.base) if n.startswith(".work-")])

    def test_an_existing_directory_is_made_private(self):
        os.makedirs(self.base, mode=0o755)
        os.chmod(self.base, 0o755)
        ca.ensure_ca(self.base)
        self.assertEqual(mode(self.base), 0o700)

    def test_the_ca_is_reused(self):
        cert = ca.ensure_ca(self.base)
        before = read(cert), read(os.path.join(self.base, "ca.key"))
        self.assertEqual(ca.ensure_ca(self.base), cert)
        self.assertEqual((read(cert), read(os.path.join(self.base, "ca.key"))), before)

    def test_a_ca_whose_key_is_gone_or_another_is_made_again(self):
        cert = ca.ensure_ca(self.base)
        first = read(cert)
        os.unlink(os.path.join(self.base, "ca.key"))
        ca.ensure_ca(self.base)
        second = read(cert)
        self.assertNotEqual(first, second)
        # A key that is not the certificate's.
        other = os.path.join(self.tmp.name, "other")
        ca.ensure_ca(other)
        shutil.copy(os.path.join(other, "ca.key"), os.path.join(self.base, "ca.key"))
        ca.ensure_ca(self.base)
        self.assertNotEqual(read(cert), second)
        self.assertEqual(openssl("verify", "-CAfile", cert, cert).returncode, 0)

    def test_the_default_base_is_under_the_home_config(self):
        with mock.patch.dict(os.environ, {"HOME": self.tmp.name}):
            self.assertEqual(ca.default_base(), os.path.join(self.tmp.name, ".config", "c4-hue-driver", "fakebox"))
            cert = ca.ensure_ca()
            leaf, key = ca.ensure_box_cert(BOX, "HSB1")
        self.assertEqual(cert, os.path.join(self.tmp.name, ".config", "c4-hue-driver", "fakebox", "ca.pem"))
        self.assertTrue(leaf.startswith(os.path.dirname(cert) + os.sep))
        self.assertTrue(os.path.isfile(key))


class LeafTest(Case):
    def test_the_leaf_has_the_real_box_shape(self):
        cert, key = ca.ensure_box_cert(BOX.lower(), "HSB2", self.base)
        self.assertEqual(cert, os.path.join(self.base, "boxes", BOX + ".pem"))
        self.assertEqual(key, os.path.join(self.base, "boxes", BOX + ".key"))
        self.assertEqual(subject(cert), "CN=%s,OU=HSB2" % BOX)
        self.assertEqual(subject(cert, "-issuer"), "CN=c4-hue fake sync box CA")
        text = text_of(cert)
        self.assertIn("NIST CURVE: P-256", text)
        self.assertNotIn("Subject Alternative Name", text)
        self.assertRegex(text, r"Basic Constraints: critical\s+CA:FALSE")
        self.assertRegex(text, r"Extended Key Usage:\s+TLS Web Server Authentication")
        self.assertIn("ecdsa-with-SHA256", text)

    def test_the_leaf_chains_to_the_fake_ca_and_never_to_root_hsb(self):
        cert, _ = ca.ensure_box_cert(BOX, "HSB2", self.base)
        good = verify(os.path.join(self.base, "ca.pem"), cert)
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        self.assertTrue(good.stdout.strip().endswith(": OK"))
        self.assertTrue(os.path.isfile(HSB_CA))
        bad = verify(HSB_CA, cert)
        self.assertNotEqual(bad.returncode, 0, "the driver's pinned root must never verify a fake box")
        self.assertIn("unable to get local issuer certificate", bad.stdout + bad.stderr)

    def test_the_chain_file_is_the_leaf_then_the_ca(self):
        cert, _ = ca.ensure_box_cert(BOX, "HSB3", self.base)
        chain = ca.box_chain_path(BOX, self.base)
        self.assertEqual(read(chain), read(cert) + read(os.path.join(self.base, "ca.pem")))

    def test_python_tls_takes_the_leaf_with_the_fake_ca_only(self):
        cert, key = ca.ensure_box_cert(BOX, "HSB2", self.base)
        peer = handshake(cert, key, os.path.join(self.base, "ca.pem"))
        self.assertIn((("commonName", BOX),), peer["subject"])
        self.assertIn((("organizationalUnitName", "HSB2"),), peer["subject"])
        with self.assertRaises(ssl.SSLCertVerificationError):
            handshake(cert, key, HSB_CA)
        # The chain file serves as well (a server that sends the CA too).
        handshake(ca.box_chain_path(BOX, self.base), key, os.path.join(self.base, "ca.pem"))

    def test_the_leaf_is_reused(self):
        cert, key = ca.ensure_box_cert(BOX, "HSB2", self.base)
        before = read(cert), read(key)
        self.assertEqual(ca.ensure_box_cert(BOX, "HSB2", self.base), (cert, key))
        self.assertEqual((read(cert), read(key)), before)

    def test_another_model_makes_the_leaf_again(self):
        cert, key = ca.ensure_box_cert(BOX, "HSB2", self.base)
        before = read(key)
        ca.ensure_box_cert(BOX, "HSB1", self.base)
        self.assertEqual(subject(cert), "CN=%s,OU=HSB1" % BOX)
        self.assertNotEqual(read(key), before)
        self.assertEqual(read(ca.box_chain_path(BOX, self.base))[: len(read(cert))], read(cert))

    def test_a_leaf_of_another_id_is_another_file(self):
        first, _ = ca.ensure_box_cert(BOX, "HSB2", self.base)
        second, _ = ca.ensure_box_cert(OTHER_BOX, "HSB2", self.base)
        self.assertNotEqual(first, second)
        self.assertEqual(subject(first), "CN=%s,OU=HSB2" % BOX)
        self.assertEqual(subject(second), "CN=%s,OU=HSB2" % OTHER_BOX)

    def test_a_leaf_edited_by_hand_is_made_again(self):
        cert, _ = ca.ensure_box_cert(BOX, "HSB2", self.base)
        other, _ = ca.ensure_box_cert(OTHER_BOX, "HSB2", self.base)
        shutil.copy(other, cert)  # the subject no longer names the id
        ca.ensure_box_cert(BOX, "HSB2", self.base)
        self.assertEqual(subject(cert), "CN=%s,OU=HSB2" % BOX)
        with open(cert, "w", encoding="ascii") as handle:
            handle.write("not a certificate\n")
        ca.ensure_box_cert(BOX, "HSB2", self.base)
        self.assertEqual(subject(cert), "CN=%s,OU=HSB2" % BOX)

    def test_a_new_ca_makes_every_leaf_again(self):
        cert, _ = ca.ensure_box_cert(BOX, "HSB2", self.base)
        os.unlink(os.path.join(self.base, "ca.key"))
        ca.ensure_box_cert(BOX, "HSB2", self.base)
        result = verify(os.path.join(self.base, "ca.pem"), cert)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_wrong_ca_is_another_ca(self):
        cert, key = ca.ensure_wrong_box_cert(BOX, "HSB2", self.base)
        self.assertEqual(os.path.dirname(os.path.dirname(cert)), ca.wrong_base(self.base))
        self.assertEqual(subject(cert), "CN=%s,OU=HSB2" % BOX)
        good = os.path.join(self.base, "ca.pem")
        ca.ensure_ca(self.base)
        self.assertNotEqual(verify(good, cert).returncode, 0)
        self.assertNotEqual(verify(HSB_CA, cert).returncode, 0)
        self.assertEqual(verify(os.path.join(ca.wrong_base(self.base), "ca.pem"), cert).returncode, 0)
        with self.assertRaises(ssl.SSLCertVerificationError):
            handshake(cert, key, good)

    def test_bad_ids_and_models_are_refused(self):
        for bad in ("0A1B2C3D4E5", "0A1B2C3D4E5FF", "0A1B2C3D4E5G", "0A:1B:2C:3D:4E:5F", "", None, 12):
            with self.assertRaises(ValueError, msg=repr(bad)):
                ca.ensure_box_cert(bad, "HSB2", self.base)
        for bad in ("", "HSB/2", "HSB 2", "HSB2,CN=x", "x" * 33, None):
            with self.assertRaises(ValueError, msg=repr(bad)):
                ca.ensure_box_cert(BOX, bad, self.base)
        self.assertFalse(os.path.exists(os.path.join(self.base, "boxes")))

    def test_concurrent_callers_agree(self):
        results, errors = [], []

        def worker():
            try:
                results.append(ca.ensure_box_cert(BOX, "HSB2", self.base))
            except Exception as error:
                errors.append(error)

        threads = [threading.Thread(target=worker) for _ in range(6)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(set(results)), 1)
        cert, _ = results[0]
        self.assertEqual(verify(os.path.join(self.base, "ca.pem"), cert).returncode, 0)


class CLITest(Case):
    def run_cli(self, *args):
        script = os.path.join(TOOLS, "fakebox", "ca.py")
        return subprocess.run(
            [sys.executable, "-I", script, "--base", self.base, *args], capture_output=True, text=True, check=False
        )

    def test_the_cli_prints_paths_and_never_a_key(self):
        proc = self.run_cli("box", BOX, "HSB2")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            proc.stdout.splitlines(),
            [os.path.join(self.base, "boxes", BOX + ".pem"), os.path.join(self.base, "boxes", BOX + ".key")],
        )
        proc_ca = self.run_cli("ca")
        self.assertEqual(proc_ca.stdout.strip(), os.path.join(self.base, "ca.pem"))
        for out in (proc.stdout + proc.stderr, proc_ca.stdout + proc_ca.stderr):
            self.assertNotIn("PRIVATE KEY", out)
            self.assertNotIn("BEGIN", out)

    def test_the_cli_refuses_a_bad_id(self):
        proc = self.run_cli("box", "nothex", "HSB2")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("12 hex digits", proc.stderr)


if __name__ == "__main__":
    unittest.main()
