# The device certificate: SCEP enrollment, validity and the OCSP revocation check.

# Relies on the hardware clock, so openssl verify also checks validity dates.
certificate_is_valid() {
  [ -f "$DOT1X_DIR/device.crt" ] && [ -f "$DOT1X_DIR/device.key" ] && [ -f "$DOT1X_DIR/ca.pem" ] \
    && openssl x509 -in "$DOT1X_DIR/device.crt" -noout -subject -nameopt multiline \
      | grep -qx " *commonName *= $COMMON_NAME" \
    && openssl verify -CAfile "$DOT1X_DIR/ca.pem" "$DOT1X_DIR/device.crt" >/dev/null
}

# Only an explicit "revoked" signed by our CA counts; no answer means unknown, and the caller
# carries on as if the certificate were good.
certificate_revoked() {
  local answer
  answer=$(openssl ocsp -issuer "$DOT1X_DIR/ca.pem" -cert "$DOT1X_DIR/device.crt" -CAfile "$DOT1X_DIR/ca.pem" \
    -url "$OCSP_URL" -timeout 8 2>&1)
  if ! grep -qx "Response verify OK" <<< "$answer"; then
    # OpenSSL starts error lines with a thread id that changes on every run; without it repeats are recognised
    log "OCSP gave no verified answer, keeping the certificate: $(tail -n 1 <<< "$answer" | sed 's/^[0-9A-F]*:error:[0-9A-F]*://')"
    return 1
  fi
  grep -q ': revoked$' <<< "$answer"
}

# scepclient checks the CA itself but does not save it; wpa_supplicant needs it as ca_cert.
fetch_ca_certificate() {
  wget -q -T 10 --tries=1 -O "$DOT1X_DIR/ca.der" "$SCEP_URL?operation=GetCACert" || return 1
  openssl x509 -inform DER -in "$DOT1X_DIR/ca.der" -out "$DOT1X_DIR/ca.pem" || return 1
  rm -f "$DOT1X_DIR/ca.der"

  local fingerprint
  fingerprint=$(openssl x509 -in "$DOT1X_DIR/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
  if [ "${fingerprint,,}" != "${CA_FINGERPRINT,,}" ]; then
    log "FAIL: CA fingerprint $fingerprint does not match the expected one"
    rm -f "$DOT1X_DIR/ca.pem"
    return 1
  fi
}

enroll() {
  log "Enrolling $COMMON_NAME at $SCEP_URL"
  fetch_ca_certificate || return 1

  # scepclient reuses an existing key and CSR, and sends a renewal instead of an
  # enrollment when the certificate file exists, so every enrollment starts clean.
  rm -f "$DOT1X_DIR/device.key" "$DOT1X_DIR/device.crt" "$DOT1X_DIR/csr.pem" "$DOT1X_DIR/self.pem"
  # scepclient has no HTTP timeout of its own; a hung request must not stall the monitor
  timeout 120 scepclient -server-url "$SCEP_URL" -challenge "$SCEP_CHALLENGE" -ca-fingerprint "$CA_FINGERPRINT" \
    -cn "$COMMON_NAME" -private-key "$DOT1X_DIR/device.key" -certificate "$DOT1X_DIR/device.crt" || return 1
  chmod 600 "$DOT1X_DIR/device.key"
  rm -f "$DOT1X_DIR/csr.pem"
  certificate_is_valid || { log "FAIL: the issued certificate does not verify"; return 1; }
  rm -f "$SWITCH_REFUSED"
  log "Certificate issued, valid until $(openssl x509 -in "$DOT1X_DIR/device.crt" -noout -enddate | cut -d= -f2)"
}
