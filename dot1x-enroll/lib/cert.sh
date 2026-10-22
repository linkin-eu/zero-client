# The device certificate: its state, the OCSP revocation check and SCEP enrollment.

# missing, invalid or valid. Relies on the hardware clock, so openssl verify also checks validity dates.
certificate_state() {
  if [ ! -f "$DOT1X_DIR/device.crt" ] || [ ! -f "$DOT1X_DIR/device.key" ] || [ ! -f "$DOT1X_DIR/ca.pem" ]; then
    echo missing
  elif openssl x509 -in "$DOT1X_DIR/device.crt" -noout -subject -nameopt multiline \
      | grep -qx " *commonName *= $COMMON_NAME" \
    && openssl verify -CAfile "$DOT1X_DIR/ca.pem" "$DOT1X_DIR/device.crt" >/dev/null 2>&1; then
    echo valid
  else
    echo invalid
  fi
}

certificate_serial() {
  openssl x509 -in "$DOT1X_DIR/device.crt" -noout -serial 2>/dev/null | cut -d= -f2
}

# yes, no or unknown. Only an explicit "revoked" signed by our CA counts. The answer is kept for
# OCSP_CHECK_EVERY seconds per certificate, so the check every few seconds does not query OCSP each time.
revocation_state() {
  local serial cached answer state
  serial=$(certificate_serial)
  if [ -f "$OCSP_CACHE" ] && [ "$(seconds_since_modified "$OCSP_CACHE")" -lt $OCSP_CHECK_EVERY ]; then
    read -r cached state < "$OCSP_CACHE"
    if [ "$cached" = "$serial" ]; then
      echo "$state"
      return
    fi
  fi
  answer=$(bounded 15 openssl ocsp -issuer "$DOT1X_DIR/ca.pem" -cert "$DOT1X_DIR/device.crt" -CAfile "$DOT1X_DIR/ca.pem" \
    -url "$OCSP_URL" -timeout 8 2>&1)
  if ! grep -qx "Response verify OK" <<< "$answer"; then
    state=unknown
  elif grep -q ': revoked$' <<< "$answer"; then
    state=yes
  else
    state=no
  fi
  echo "$serial $state" > "$OCSP_CACHE"
  echo "$state"
}

# scepclient checks the CA itself but does not save it; wpa_supplicant needs it as ca_cert.
fetch_ca_certificate() {
  wget -q -T 10 --tries=1 -O "$DOT1X_DIR/ca.der" "$SCEP_URL?operation=GetCACert" || return 1
  openssl x509 -inform DER -in "$DOT1X_DIR/ca.der" -out "$DOT1X_DIR/ca.pem" || return 1
  rm -f "$DOT1X_DIR/ca.der"

  local fingerprint
  fingerprint=$(openssl x509 -in "$DOT1X_DIR/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d :)
  if [ "${fingerprint,,}" != "${CA_FINGERPRINT,,}" ]; then
    rm -f "$DOT1X_DIR/ca.pem"
    log_failure "CA fingerprint $fingerprint does not match the expected one"
    return 1
  fi
}

enroll_certificate() {
  if ! fetch_ca_certificate; then
    log_failure "no CA certificate from $SCEP_URL"
    return 1
  fi
  # scepclient reuses an existing key and CSR, and sends a renewal instead of an
  # enrollment when the certificate file exists, so every enrollment starts clean.
  rm -f "$DOT1X_DIR/device.key" "$DOT1X_DIR/device.crt" "$DOT1X_DIR/csr.pem" "$DOT1X_DIR/self.pem" "$OCSP_CACHE"
  # scepclient has no HTTP timeout of its own; a hung request must not stall the controller
  if ! timeout "$SCEP_TIMEOUT" scepclient -server-url "$SCEP_URL" -challenge "$SCEP_CHALLENGE" \
      -ca-fingerprint "$CA_FINGERPRINT" -cn "$COMMON_NAME" \
      -private-key "$DOT1X_DIR/device.key" -certificate "$DOT1X_DIR/device.crt" >/dev/null 2>&1; then
    log_failure "SCEP enrollment of $COMMON_NAME at $SCEP_URL"
    return 1
  fi
  chmod 600 "$DOT1X_DIR/device.key"
  rm -f "$DOT1X_DIR/csr.pem"
  if [ "$(certificate_state)" != valid ]; then
    log_failure "the issued certificate does not verify"
    return 1
  fi
  # The last refusal was for the old certificate, so the new one is tried at once
  rm -f "$SWITCH_REFUSED"
  log "Certificate $(certificate_serial) issued, valid until $(openssl x509 -in "$DOT1X_DIR/device.crt" -noout -enddate | cut -d= -f2)"
}

# A revoked certificate is replaced from the onboarding VLAN, the only one that reaches SCEP
drop_revoked_certificate() {
  log "Certificate $(certificate_serial) is revoked, replacing it"
  [ "$fact_mode" = dot1x ] && leave_dot1x
  rm -f "$DOT1X_DIR/device.crt" "$OCSP_CACHE"
}
