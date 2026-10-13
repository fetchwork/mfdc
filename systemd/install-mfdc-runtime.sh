#!/usr/bin/env bash
# Подготовка ОС: все сервисы MFDC запускаются от freeswitch:freeswitch.
set -euo pipefail

MFDC_USER="${MFDC_USER:-freeswitch}"
MFDC_GROUP="${MFDC_GROUP:-freeswitch}"

if ! getent group "$MFDC_GROUP" >/dev/null; then
  echo "ERROR: group $MFDC_GROUP not found (install FreeSWITCH first)" >&2
  exit 1
fi

if ! getent passwd "$MFDC_USER" >/dev/null; then
  echo "ERROR: user $MFDC_USER not found (install FreeSWITCH first)" >&2
  exit 1
fi

sudo mkdir -p /opt/mfdc /var/log/mfdc
# freeswitch пишет mfdc-api.lock сюда — каталог должен быть group-writable
sudo chown root:"$MFDC_GROUP" /opt/mfdc
sudo chmod 2775 /opt/mfdc
sudo chown "$MFDC_USER:$MFDC_GROUP" /var/log/mfdc
sudo chmod 0755 /var/log/mfdc

sudo mkdir -p /var/cache/freeswitch
sudo chown freeswitch:freeswitch /var/cache/freeswitch
sudo chmod 0755 /var/cache/freeswitch
echo "OK: /var/cache/freeswitch for FreeSWITCH mod_http_cache"

RECORDINGS_DIR="${RECORDINGS_DIR:-/var/lib/freeswitch/recordings/mfdc}"
sudo mkdir -p "$RECORDINGS_DIR"
sudo chown freeswitch:freeswitch "$RECORDINGS_DIR"
sudo chmod 2775 "$RECORDINGS_DIR"
echo "OK: $RECORDINGS_DIR (recordings WAV/MP3, freeswitch:freeswitch)"

SOUNDS_DIR="${SOUNDS_DIR:-/var/lib/freeswitch/sounds/mfdc}"
sudo mkdir -p "$SOUNDS_DIR"
sudo chown freeswitch:freeswitch "$SOUNDS_DIR"
sudo chmod 2775 "$SOUNDS_DIR"
echo "OK: $SOUNDS_DIR (IVR/MOH media library)"

if [[ -f /opt/mfdc/settings.conf ]]; then
  sudo chown root:freeswitch /opt/mfdc/settings.conf
  sudo chmod 0640 /opt/mfdc/settings.conf
fi

for bin in /opt/mfdc/mfdc-api /opt/mfdc/mfdc-broker /opt/mfdc/mfdc-runner /opt/mfdc/mfdc-caller; do
  if [[ -f "$bin" ]]; then
    sudo chown "$MFDC_USER:$MFDC_GROUP" "$bin"
    sudo chmod 0755 "$bin"
  fi
done

if [[ -d /opt/mfdc/licence ]]; then
  sudo chown -R root:freeswitch /opt/mfdc/licence
  sudo find /opt/mfdc/licence -type d -exec chmod 0750 {} \;
  if [[ -f /opt/mfdc/licence/mfdc-licence ]]; then
    sudo chown freeswitch:freeswitch /opt/mfdc/licence/mfdc-licence
    sudo chmod 0755 /opt/mfdc/licence/mfdc-licence
  fi
  if [[ -f /opt/mfdc/licence/private.key ]]; then
    sudo chmod 0640 /opt/mfdc/licence/private.key
  fi
  if [[ -f /opt/mfdc/licence/public.key ]]; then
    sudo chmod 0644 /opt/mfdc/licence/public.key
  fi
fi

echo "OK: MFDC services run as $MFDC_USER:$MFDC_GROUP"
echo "Install units: sudo cp install/systemd/mfdc-*.service /etc/systemd/system/ && sudo systemctl daemon-reload"
