#!/usr/bin/env bash
#
# Generate ECP256 SPDM test keys for ASPEED Renode tests.
#
# Produces:
#   test-keys/sample/        - 3-deep chain (CA -> inter -> end), used by most scenarios
#                              Includes end_responder.key.p8 and end_requester.key.p8
#                              (the latter as a "wrong key" for *-bad-key scenarios)
#   test-keys/large-chain/   - 5-deep chain (CA -> 3 intermediates -> end), used by
#                              -large-chain scenario to exercise multi-cert chunking
#
# Cert extensions match libspdm's openssl.cnf (v3_inter / v3_end), so a libspdm
# requester (e.g. the BMC's spdm-emu / spdm_requester) accepts the chain.
#
# Run from anywhere; output is always tests/peripherals/Aspeed/test-keys/.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="${SCRIPT_DIR}/test-keys"
SAMPLE="${OUT_ROOT}/sample"
LARGE="${OUT_ROOT}/large-chain"

# Minimal openssl.cnf carrying the v3_inter / v3_end extension blocks libspdm uses.
TMPCNF="$(mktemp -t spdm-keygen.XXXXXX.cnf)"
cleanup() { rm -f "$TMPCNF"; }
trap cleanup EXIT

cat > "$TMPCNF" <<'EOF'
[ v3_inter ]
basicConstraints = CA:true
keyUsage = cRLSign, keyCertSign, digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment, keyAgreement
extendedKeyUsage = critical, serverAuth, clientAuth

[ v3_end ]
basicConstraints = critical,CA:false
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = otherName:1.3.6.1.4.1.412.274.1;UTF8:ACME:WIDGET:1234567890
extendedKeyUsage = critical, serverAuth, clientAuth, OCSPSigning
EOF

mkdir -p "$SAMPLE" "$LARGE"

# ---------------------------------------------------------------------------
# sample/ : 3-deep chain (CA -> inter -> end)
# ---------------------------------------------------------------------------
echo "==> generating sample/ (3-deep ECP256 chain)"
(
  cd "$SAMPLE"
  openssl genpkey -genparam -out param.pem -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null

  openssl req -nodes -x509 -days 3650 -newkey ec:param.pem \
    -keyout ca.key -out ca.cert -sha256 \
    -subj "/CN=Renode SPDM ECP256 CA" 2>/dev/null

  openssl req -nodes -newkey ec:param.pem -keyout inter.key -out inter.req \
    -sha256 -batch -subj "/CN=Renode SPDM ECP256 intermediate" 2>/dev/null
  openssl x509 -req -in inter.req -out inter.cert -CA ca.cert -CAkey ca.key \
    -sha256 -days 3650 -set_serial 1 -extensions v3_inter -extfile "$TMPCNF" 2>/dev/null

  openssl req -nodes -newkey ec:param.pem -keyout end_responder.key \
    -out end_responder.req -sha256 -batch \
    -subj "/CN=Renode SPDM ECP256 responder" 2>/dev/null
  openssl x509 -req -in end_responder.req -out end_responder.cert \
    -CA inter.cert -CAkey inter.key -sha256 -days 3650 -set_serial 2 \
    -extensions v3_end -extfile "$TMPCNF" 2>/dev/null

  openssl req -nodes -newkey ec:param.pem -keyout end_requester.key \
    -out end_requester.req -sha256 -batch \
    -subj "/CN=Renode SPDM ECP256 requester" 2>/dev/null
  openssl x509 -req -in end_requester.req -out end_requester.cert \
    -CA inter.cert -CAkey inter.key -sha256 -days 3650 -set_serial 3 \
    -extensions v3_end -extfile "$TMPCNF" 2>/dev/null

  openssl asn1parse -in ca.cert -out ca.cert.der >/dev/null
  openssl asn1parse -in inter.cert -out inter.cert.der >/dev/null
  openssl asn1parse -in end_responder.cert -out end_responder.cert.der >/dev/null

  cat ca.cert.der inter.cert.der end_responder.cert.der > bundle_responder.certchain.der

  openssl ec -inform PEM -outform DER -in end_responder.key \
    -out end_responder.key.der 2>/dev/null
  openssl pkcs8 -in end_responder.key.der -inform DER -topk8 -nocrypt \
    -outform DER > end_responder.key.p8

  openssl ec -inform PEM -outform DER -in end_requester.key \
    -out end_requester.key.der 2>/dev/null
  openssl pkcs8 -in end_requester.key.der -inform DER -topk8 -nocrypt \
    -outform DER > end_requester.key.p8

  rm -f param.pem *.req *.cert *.key *.der.tmp ca.key inter.key end_responder.key end_requester.key
  rm -f end_responder.key.der end_requester.key.der ca.cert.der inter.cert.der end_responder.cert.der
)

# ---------------------------------------------------------------------------
# large-chain/ : 5-deep chain (CA -> inter1 -> inter2 -> inter3 -> end)
# ---------------------------------------------------------------------------
echo "==> generating large-chain/ (5-deep ECP256 chain)"
(
  cd "$LARGE"
  openssl genpkey -genparam -out param.pem -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null

  openssl req -nodes -x509 -days 3650 -newkey ec:param.pem \
    -keyout root_ca.key -out root_ca.cert -sha256 \
    -subj "/CN=Renode SPDM ECP256 root CA" 2>/dev/null

  prev_cert=root_ca.cert
  prev_key=root_ca.key

  for i in 1 2 3; do
    openssl req -nodes -newkey ec:param.pem -keyout inter${i}.key \
      -out inter${i}.req -sha256 -batch \
      -subj "/CN=Renode SPDM ECP256 inter${i}" 2>/dev/null
    openssl x509 -req -in inter${i}.req -out inter${i}.cert \
      -CA "$prev_cert" -CAkey "$prev_key" -sha256 -days 3650 \
      -set_serial $((10 + i)) -extensions v3_inter -extfile "$TMPCNF" 2>/dev/null
    prev_cert=inter${i}.cert
    prev_key=inter${i}.key
  done

  openssl req -nodes -newkey ec:param.pem -keyout end_responder.key \
    -out end_responder.req -sha256 -batch \
    -subj "/CN=Renode SPDM ECP256 responder (deep)" 2>/dev/null
  openssl x509 -req -in end_responder.req -out end_responder.cert \
    -CA "$prev_cert" -CAkey "$prev_key" -sha256 -days 3650 -set_serial 99 \
    -extensions v3_end -extfile "$TMPCNF" 2>/dev/null

  openssl asn1parse -in root_ca.cert -out root_ca.cert.der >/dev/null
  openssl asn1parse -in inter1.cert -out inter1.cert.der >/dev/null
  openssl asn1parse -in inter2.cert -out inter2.cert.der >/dev/null
  openssl asn1parse -in inter3.cert -out inter3.cert.der >/dev/null
  openssl asn1parse -in end_responder.cert -out end_responder.cert.der >/dev/null

  cat root_ca.cert.der inter1.cert.der inter2.cert.der inter3.cert.der \
      end_responder.cert.der > bundle_responder.certchain.der

  openssl ec -inform PEM -outform DER -in end_responder.key \
    -out end_responder.key.der 2>/dev/null
  openssl pkcs8 -in end_responder.key.der -inform DER -topk8 -nocrypt \
    -outform DER > end_responder.key.p8

  rm -f param.pem *.req *.cert *.key *.srl *.der.tmp
  rm -f root_ca.cert.der inter1.cert.der inter2.cert.der inter3.cert.der end_responder.cert.der
  rm -f end_responder.key.der
)

echo ""
echo "Done. Generated:"
echo "  ${SAMPLE}/bundle_responder.certchain.der"
echo "  ${SAMPLE}/end_responder.key.p8         (matches the chain)"
echo "  ${SAMPLE}/end_requester.key.p8         (different end-leaf key — used as wrong-key in *-bad-key scenarios)"
echo "  ${LARGE}/bundle_responder.certchain.der  (5-deep chain)"
echo "  ${LARGE}/end_responder.key.p8"
