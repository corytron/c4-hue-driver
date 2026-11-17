#!/usr/bin/env python3
"""The fake Hue Sync Box's certificates: a CA of this VM and one leaf per box (#547, docs/fakebox-design.md §5).

A real box presents a leaf whose common name is its id (12 upper-case hex digits) and whose
organisational unit names its model, issued directly by Signify's self-signed root CN=root-hsb, an
EC P-256 key (docs/syncbox-architecture-research.md §2.2). The fake copies that shape under its own
root, so nothing it serves can ever verify against the driver's pinned src/hue_syncbox/certs/hsb_ca.pem:

  CA    CN=c4-hue fake sync box CA, EC P-256, self-signed, basicConstraints critical CA:TRUE,
        keyUsage critical keyCertSign and cRLSign
  leaf  CN=<box id upper case>, OU=<model>, EC P-256, signed by the CA, no subjectAltName (as the
        real box: the driver checks the id at the application layer, never the name),
        basicConstraints critical CA:FALSE, keyUsage critical digitalSignature,
        extendedKeyUsage serverAuth

Files, under BASE (default ~/.config/c4-hue-driver/fakebox/, a directory of mode 0700; never the
repository, never a release build):

  ca.pem, ca.key                        the CA (tools/build.sh --dev appends ca.pem to the dev
                                        package's certs/hsb_ca.pem, §7)
  boxes/<ID>.pem, <ID>.key              a box's leaf and its key
  boxes/<ID>-chain.pem                  the leaf followed by the CA, for a server that sends both
  wrong/...                             the same layout under another CA (ensure_wrong_box_cert),
                                        for the "wrong certificate" fault of §2

Every key file has mode 0600 and is written by this module, never printed. The keys and certificates
are made by the openssl command (argument lists, no shell); the module is standard library only and
runs under python3 -I. Everything is idempotent: a call reuses what is there when it is still right
(the subject, the key matching the certificate, the leaf verifying against the current CA, more than
30 days left) and makes it again otherwise, so a leaf whose id or model differs, or one left over from
an older CA, is replaced. One process at a time per BASE (an flock on BASE/.lock).

API:
  default_base() -> str
  ensure_ca(base=None) -> ca_cert_path
  ensure_box_cert(box_id, model, base=None) -> (cert_path, key_path)
  box_chain_path(box_id, base=None) -> path of the leaf+CA file (made by ensure_box_cert)
  ensure_wrong_box_cert(box_id, model, base=None) -> (cert_path, key_path), from a second CA under
      BASE/wrong/ that the first never trusts

CLI (prints paths only):
  python3 -I tools/fakebox/ca.py [--base DIR] ca
  python3 -I tools/fakebox/ca.py [--base DIR] box <BOX ID> <MODEL>
"""

import argparse
import contextlib
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

CA_CN = "c4-hue fake sync box CA"
CA_DAYS = 3650
LEAF_DAYS = 3650
# A certificate with less than this left is made again.
RENEW_SECONDS = 30 * 86400
BOX_ID_RE = re.compile(r"^[0-9A-Fa-f]{12}$")
# Model names as the box reports them (HSB1, HSB2, HSB3, HSC001): letters, digits, "_" and "-", which
# need no escaping in an openssl -subj or an RFC 2253 subject.
MODEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,32}$")

# The openssl configuration of every `req` and of the leaf's extensions: written beside the files,
# so the system's openssl.cnf adds nothing.
OPENSSL_CNF = """\
[req]
distinguished_name = dn
prompt = no
[dn]
[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
[v3_leaf]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
"""


class CAError(RuntimeError):
    """openssl failed or is missing; the message never holds key material."""


def default_base():
    """~/.config/c4-hue-driver/fakebox (XDG_CONFIG_HOME is not read: one fixed place, as the dev key)."""
    return os.path.join(os.path.expanduser("~"), ".config", "c4-hue-driver", "fakebox")


def _openssl():
    path = shutil.which("openssl")
    if not path:
        raise CAError("the openssl command is not installed")
    return path


def _run(args, *, input_bytes=None, check=True):
    """openssl with these arguments; its stdout as bytes. stderr is kept for the error only."""
    proc = subprocess.run(
        [_openssl(), *args],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if check and proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise CAError("openssl %s failed: %s" % (args[0], detail[-1] if detail else "exit %d" % proc.returncode))
    return proc


def _private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def _write(path, data, mode):
    """`data` into `path` atomically: a temporary file of `mode` in the same directory, then a rename."""
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


@contextlib.contextmanager
def _locked(base):
    import fcntl  # POSIX only; imported here so that importing the module never needs it

    _private_dir(base)
    fd = os.open(os.path.join(base, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _new_key():
    """A new EC P-256 private key, PEM (PKCS #8), as bytes; never written anywhere but by _write."""
    return _run(["genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256"]).stdout


def _serial():
    return "0x%016x" % (secrets.randbits(63) | 1)


def _subject(cert):
    proc = _run(["x509", "-in", cert, "-noout", "-subject", "-nameopt", "RFC2253"], check=False)
    if proc.returncode != 0:
        return None
    text = proc.stdout.decode("utf-8", "replace").strip()
    return text[len("subject=") :].strip() if text.startswith("subject=") else None


def _pubkey_of_cert(cert):
    proc = _run(["x509", "-in", cert, "-noout", "-pubkey"], check=False)
    return proc.stdout if proc.returncode == 0 else None


def _pubkey_of_key(key):
    proc = _run(["pkey", "-in", key, "-pubout"], check=False)
    return proc.stdout if proc.returncode == 0 else None


def _lasts(cert):
    return _run(["x509", "-in", cert, "-noout", "-checkend", str(RENEW_SECONDS)], check=False).returncode == 0


def _verifies(cert, ca_cert):
    proc = _run(["verify", "-CAfile", ca_cert, "-purpose", "sslserver", cert], check=False)
    return proc.returncode == 0 and proc.stdout.decode("utf-8", "replace").strip().endswith(": OK")


def _usable(cert, key, subject, ca_cert=None):
    """True when cert and key exist, the subject is `subject`, the key is the cert's, it lasts, and
    (for a leaf) it verifies against ca_cert."""
    if not (os.path.isfile(cert) and os.path.isfile(key)):
        return False
    if _subject(cert) != subject or not _lasts(cert):
        return False
    pub = _pubkey_of_cert(cert)
    if not pub or pub != _pubkey_of_key(key):
        return False
    return ca_cert is None or _verifies(cert, ca_cert)


def _resolve(base):
    return os.path.abspath(os.path.expanduser(base)) if base else default_base()


def _ca_paths(base):
    return os.path.join(base, "ca.pem"), os.path.join(base, "ca.key")


def _box_id(box_id):
    if not isinstance(box_id, str) or not BOX_ID_RE.match(box_id):
        raise ValueError("a box id is 12 hex digits, not %r" % (box_id,))
    return box_id.upper()


def _model(model):
    if not isinstance(model, str) or not MODEL_RE.match(model):
        raise ValueError("a model is 1 to 32 letters, digits, '_' or '-', not %r" % (model,))
    return model


def _ensure_ca_locked(base):
    cert, key = _ca_paths(base)
    if _usable(cert, key, "CN=" + CA_CN):
        return cert
    with tempfile.TemporaryDirectory(dir=base, prefix=".work-") as work:
        cnf = os.path.join(work, "openssl.cnf")
        with open(cnf, "w", encoding="utf-8") as handle:
            handle.write(OPENSSL_CNF)
        _write(key, _new_key(), 0o600)
        pem = _run(
            [
                "req", "-config", cnf, "-new", "-x509", "-key", key, "-subj", "/CN=" + CA_CN,
                "-days", str(CA_DAYS), "-sha256", "-extensions", "v3_ca", "-set_serial", _serial(),
            ]
        ).stdout  # fmt: skip
        _write(cert, pem, 0o644)
    return cert


def ensure_ca(base=None):
    """The CA certificate's path under `base`, made (with its key) when missing or no longer right."""
    base = _resolve(base)
    with _locked(base):
        return _ensure_ca_locked(base)


def _leaf_paths(base, box_id):
    boxes = os.path.join(base, "boxes")
    return (
        os.path.join(boxes, box_id + ".pem"),
        os.path.join(boxes, box_id + ".key"),
        os.path.join(boxes, box_id + "-chain.pem"),
    )


def ensure_box_cert(box_id, model, base=None):
    """(cert_path, key_path) of the box's leaf under `base`: CN=<box id upper case>, OU=<model>, signed by
    ensure_ca(base). Made again when missing, for another id or model, not signed by the current CA, or
    near its end. Also writes box_chain_path(box_id, base), the leaf followed by the CA."""
    box_id, model = _box_id(box_id), _model(model)
    base = _resolve(base)
    with _locked(base):
        ca_cert = _ensure_ca_locked(base)
        _, ca_key = _ca_paths(base)
        _private_dir(os.path.join(base, "boxes"))
        cert, key, chain = _leaf_paths(base, box_id)
        if not _usable(cert, key, "CN=%s,OU=%s" % (box_id, model), ca_cert):
            with tempfile.TemporaryDirectory(dir=base, prefix=".work-") as work:
                cnf = os.path.join(work, "openssl.cnf")
                with open(cnf, "w", encoding="utf-8") as handle:
                    handle.write(OPENSSL_CNF)
                _write(key, _new_key(), 0o600)
                csr = _run(["req", "-config", cnf, "-new", "-key", key, "-subj", "/OU=%s/CN=%s" % (model, box_id)])
                pem = _run(
                    [
                        "x509", "-req", "-in", "-", "-CA", ca_cert, "-CAkey", ca_key, "-set_serial", _serial(),
                        "-days", str(LEAF_DAYS), "-sha256", "-extfile", cnf, "-extensions", "v3_leaf",
                    ],
                    input_bytes=csr.stdout,
                ).stdout  # fmt: skip
                _write(cert, pem, 0o644)
        with open(cert, "rb") as leaf, open(ca_cert, "rb") as root:
            want = leaf.read() + root.read()
        current = None
        if os.path.isfile(chain):
            with open(chain, "rb") as handle:
                current = handle.read()
        if current != want:
            _write(chain, want, 0o644)
        return cert, key


def box_chain_path(box_id, base=None):
    """The leaf+CA file of ensure_box_cert(box_id, ..., base) (made by that call)."""
    return _leaf_paths(_resolve(base), _box_id(box_id))[2]


def wrong_base(base=None):
    """The directory of the second CA, which the first never trusts."""
    return os.path.join(_resolve(base), "wrong")


def ensure_wrong_box_cert(box_id, model, base=None):
    """A leaf of the right id and model from another CA (BASE/wrong/), for the "wrong certificate"
    fault: the driver's bundle with the fake CA refuses it, as it would a stranger's box."""
    return ensure_box_cert(box_id, model, base=wrong_base(base))


def main(argv=None):
    parser = argparse.ArgumentParser(description="The fake sync box's CA and leaves (paths only, never keys).")
    parser.add_argument("--base", help="directory of the files (default %s)" % default_base())
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ca", help="make the CA if needed; print its certificate's path")
    box = sub.add_parser("box", help="make a box's leaf if needed; print the certificate's and key's paths")
    box.add_argument("box_id")
    box.add_argument("model")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "ca":
            print(ensure_ca(args.base))
        else:
            cert, key = ensure_box_cert(args.box_id, args.model, args.base)
            print(cert)
            print(key)
    except (CAError, ValueError, OSError) as error:
        print("ca.py: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
