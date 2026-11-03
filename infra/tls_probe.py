import ssl, socket, sys

HOST = "192.168.1.21"
PORT = 8883
CA = r"D:/project X/SHE-V3/infra/ca/ca_bundle.pem"
CRT = r"D:/project X/SHE-V3/infra/ca/out/devices/she-backend.crt"
KEY = r"D:/project X/SHE-V3/infra/ca/out/devices/she-backend.key"
PWFILE = r"D:/project X/SHE-V3/infra/ca/step-ca-provisioner-password.txt"

with open(PWFILE) as f:
    pw = f.read().strip()

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED
ctx.load_verify_locations(CA)
ctx.load_cert_chain(CRT, KEY, password=pw)
ctx.minimum_version = ssl.TLSVersion.TLSv1_2
ctx.maximum_version = ssl.TLSVersion.TLSv1_2

try:
    with socket.create_connection((HOST, PORT), timeout=10) as sock:
        with ctx.wrap_socket(sock, server_hostname=HOST) as ssock:
            cert = ssock.getpeercert()
            print("HANDSHAKE_OK")
            print("TLS:", ssock.version(), "CIPHER:", ssock.cipher()[0])
            print("PEER_SUBJECT:", dict(x[0] for x in cert.get("subject", [])))
            print("PEER_SAN:", cert.get("subjectAltName"))
            print("CERT_VERIFIED_OK (hostname + chain)")
except Exception as e:
    print("HANDSHAKE_FAIL:", repr(e))
    sys.exit(1)
