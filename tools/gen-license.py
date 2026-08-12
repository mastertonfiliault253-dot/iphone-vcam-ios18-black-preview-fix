"""VCAM License Generator — RSA-2048 sign device UDID + expiry date."""
import sys, os, plistlib, base64
from datetime import datetime
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.backends import default_backend

KEY_DIR = os.path.dirname(__file__)
PRIV_KEY = os.path.join(KEY_DIR, "license_key.pem")

def gen_license(udid, expiry_date="2099-12-31"):
    with open(PRIV_KEY, "rb") as f:
        priv = serialization.load_pem_private_key(f.read(), None, default_backend())
    payload = f"{udid}|{expiry_date}".encode()
    sig = priv.sign(payload, padding.PKCS1v15(), hashes.SHA256())
    return {
        "udid": udid,
        "expiry": expiry_date,
        "sig": base64.b64encode(sig).decode(),
    }


def print_license(lic):
    import io, base64
    bdata = io.BytesIO()
    plistlib.dump(lic, bdata, fmt=plistlib.FMT_BINARY)
    b64 = base64.b64encode(bdata.getvalue()).decode()
    print('=== Paste this into the device dialog ===')
    print(b64)
    print('=== END ===')

if __name__ == "__main__":

    if len(sys.argv) < 2:
        print("Usage: python gen-license.py <UDID> [expiry_date YYYY-MM-DD]")
        print("  Expiry defaults to 2099-12-31 (never)")
        sys.exit(1)
    udid = sys.argv[1].strip().upper()
    expiry = sys.argv[2] if len(sys.argv) > 2 else "2099-12-31"
    lic = gen_license(udid, expiry)
    out = sys.argv[3] if len(sys.argv) > 3 else "license.plist"
    bdata = io.BytesIO(); plistlib.dump(lic, bdata, fmt=plistlib.FMT_BINARY); open(out, "wb").write(bdata.getvalue())
    print_license(lic)
    
