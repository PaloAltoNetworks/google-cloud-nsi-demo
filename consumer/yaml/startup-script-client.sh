#!/bin/bash
apt-get update 
apt-get install apache2-utils mtr iperf3 tcpdump -y
set -euo pipefail

SECRET_NAME="ngfw-ca"   # <-- replace with your Secret Manager secret name
CERT_FILE="ngfw-ca.crt"
TMP_CERT="/tmp/${CERT_FILE}"

echo "[INFO] Fetching CA cert from Secret Manager..."
# Requires VM service account to have role: roles/secretmanager.secretAccessor
gcloud secrets versions access latest --secret="${SECRET_NAME}" > "${TMP_CERT}"

# Detect distro family
if [ -f /etc/debian_version ]; then
  echo "[INFO] Detected Debian/Ubuntu"
  install_path="/usr/local/share/ca-certificates/${CERT_FILE}"
  sudo cp "${TMP_CERT}" "${install_path}"
  sudo update-ca-certificates
  echo "[INFO] Installed CA into Debian/Ubuntu trust store"

elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
  echo "[INFO] Detected RHEL/CentOS/Fedora"
  install_path="/etc/pki/ca-trust/source/anchors/${CERT_FILE}"
  sudo cp "${TMP_CERT}" "${install_path}"
  sudo update-ca-trust extract
  echo "[INFO] Installed CA into RHEL trust store"

else
  echo "[WARN] Unknown distro, installing cert in /etc/ssl/certs manually"
  sudo mkdir -p /etc/ssl/certs
  sudo cp "${TMP_CERT}" "/etc/ssl/certs/${CERT_FILE}"
fi

rm -f "${TMP_CERT}"
echo "[INFO] Done. System trust chain updated."
