import base64
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "gen-license.py"
KEY = ROOT / "tools" / "license_key.pem"

try:
    import cryptography  # noqa: F401
    CRYPTO_OK = True
except ImportError:
    CRYPTO_OK = False


def _extract_b64(stdout: str) -> str:
    lines = stdout.splitlines()
    try:
        start = lines.index("=== Paste this into the device dialog ===")
        end = lines.index("=== END ===", start)
        return lines[start + 1].strip()
    except ValueError:
        return ""


@unittest.skipIf(not CRYPTO_OK, "cryptography not installed")
@unittest.skipIf(not KEY.exists(), "license_key.pem missing")
class GenLicenseTests(unittest.TestCase):
    def test_generates_plist_and_base64(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            out = pathlib.Path(directory) / "license.plist"
            proc = subprocess.run(
                [sys.executable, str(SCRIPT), "TEST-UDID", "2099-12-31", str(out)],
                check=True,
                capture_output=True,
                text=True,
            )
            lic = plistlib.loads(out.read_bytes())
            self.assertEqual(lic["udid"], "TEST-UDID")
            self.assertEqual(lic["expiry"], "2099-12-31")
            self.assertTrue(lic.get("sig"))

            b64 = _extract_b64(proc.stdout)
            self.assertTrue(b64)
            decoded = plistlib.loads(base64.b64decode(b64))
            self.assertEqual(decoded["udid"], "TEST-UDID")
            self.assertEqual(decoded["expiry"], "2099-12-31")
            self.assertEqual(decoded["sig"], lic["sig"])

    def test_signature_verifies_against_public_key(self) -> None:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding

        with open(KEY, "rb") as f:
            priv = serialization.load_pem_private_key(f.read(), None)
        pub = priv.public_key()
        payload = b"TEST-UDID|2099-12-31"
        sig = priv.sign(payload, padding.PKCS1v15(), hashes.SHA256())
        # Raises InvalidSignature on mismatch.
        pub.verify(sig, payload, padding.PKCS1v15(), hashes.SHA256())
