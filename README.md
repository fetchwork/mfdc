# MFDC

Self-hosted PBX and contact center: FreeSWITCH, OpenSIPS, PostgreSQL, RabbitMQ, and a web panel.

This repository is a ready-to-install package for Debian 12 (bookworm) amd64. Nothing is compiled on the server. The installer uses the binaries and the web UI shipped here.

Without a licence file the product runs as a demo. A commercial licence removes the demo limits. Contact [Telegram @voip_dmitiy](https://t.me/voip_dmitiy).

The panel opens in **English**. Russian is available from the language switch in the top bar. A purchased licence can restrict the panel to the languages it grants.

## Demo

No licence file is required. Until a licence is installed, each domain is limited to:

- **10** SIP devices
- **5** contact-center operators

The rest of the product is available. An expired or invalid licence stops service. Having no licence does not.

## Buying a licence

1. Install MFDC and open **Licences** in the panel.
2. Download the request and send it on Telegram: [t.me/voip_dmitiy](https://t.me/voip_dmitiy).
3. Upload the `licence.json` you receive on the same page.

The verification public key is already in this package (`public.key`). The installer writes it into the database.

## Install

You need root, Debian 12 amd64, and a DNS A record pointing at the server. FreeSWITCH packages require a SignalWire personal token (`TOKEN`).

```bash
git clone https://github.com/fetchwork/mfdc.git
cd mfdc
unzip -o ui.zip -d ui
export TOKEN='xxxxxxxx'
# optional; otherwise the script asks:
# export MFDC_DOMAIN=pbx.example.com LE_EMAIL=admin@example.com
bash install.sh
```

The script asks for the domain and a Let's Encrypt email, then installs FreeSWITCH, PostgreSQL, OpenSIPS, RabbitMQ, rtpengine, nginx, the panel, and the `mfdc-*` services.

The default PostgreSQL password is `mfdc_passwd` (role `mfdc_admin`, database `mfdc`). Set your own with `MFDC_PG_PASS` before the first run.

SIP from the internet is accepted only from your providers and office. Put those addresses in `nftables/sip_allow.list`, or answer the prompt (`SIP_ALLOW=203.0.113.10,198.51.100.0/24`).

Lab install without TLS: `HTTP_ONLY=1`.

## Update

```bash
cd /path/to/mfdc
git pull
unzip -o ui.zip -d ui
bash install.sh -update
```

`-update` copies binaries to `/opt/mfdc` and the panel to `/var/www/mfdc-ui`, keeps the previous copy in `/opt/mfdc/backup`, and restarts only what changed.

Roll back:

```bash
bash install.sh -update-rollback
```

## After install

```bash
systemctl status mfdc-runner mfdc-api mfdc-broker opensips freeswitch rabbitmq-server
```

Open `https://your-domain/`. Then add extensions, trunks, and call flows.

Other switches: `SKIP_DOCKER=1`, `SKIP_ML=1`, `SKIP_FIREWALL=1`, `FORCE_CONFIG=1`. The full list is at the top of `install.sh`.
