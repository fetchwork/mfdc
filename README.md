# MFDC

MFDC is a company phone system and contact center you install on your own server. Calls reach a person, queues keep the ones that wait, and you can see what was said without listening to every recording by hand. Recordings, history, and transcription stay on your infrastructure. Download it and try the demo. No licence file is required.

The panel opens in English. Russian is in the language switch at the top.

## What it does

**Visual call flows.** Draw the call: a greeting, a keypad menu, working hours and holidays, a queue, voicemail, a quality survey, a recording, and a notification. Save the drawing and the next call follows it.

**Phones and trunks.** Internal numbers on a desk phone or in the browser. Staff call each other and transfer from the handset. Inbound numbers land on a flow. Outbound routes pick the trunk, the caller ID, and who is allowed to dial out. Calendars and number lists decide what happens next.

**Operator desk.** A browser tab and a headset. Ready and pause, pause after the current call, auto-answer, team chat, missed calls, and a sound check before the shift.

**Queues.** Calls go to the right operator: hunt, least-recent, round-robin, or ring everyone. Skills and priority narrow the pool. A returning caller can reach the same operator again. From the queue the caller can ask for a callback and hear their place in line.

**Outbound campaigns.** Progressive, predictive, and ratio dialing. The dialer keeps operators busy and watches how many callers hang up while waiting. Answering machines can be detected and dropped before an operator is offered the call. Outbound numbers rotate, and each campaign has its own hours and attempt limits.

**Supervisor.** A live board of who is waiting, who is talking, and who is free, with service level and expected wait. Listen to a call, whisper to the operator, or join the conversation. Pause an operator, and read the ratings customers leave after the call.

**Call history.** Duration, outcome, the recording, and a line-quality score. Export the journal to Excel. Send it to a CRM, and start a call from the CRM in one click.

**Transcription on your server.** Recorded calls become text, split into customer and operator. Topics such as a sale, a complaint, or a product question are tagged automatically, and a supervisor’s corrections teach the model. A live audio copy can stream to your own AI while the call is still going.

**Access.** Roles and custom permissions, two-factor sign-in, and company login through LDAP, Active Directory, OIDC, or SAML. An audit log of who changed what. Alerts for unusual calling patterns, and a lockout after repeated wrong SIP passwords.

**It keeps running.** Several FreeSWITCH nodes, with a node taken out of service when it stops answering. Health checks and Prometheus metrics. Recordings on disk or in your own S3 bucket. A backup of the whole configuration, restored onto this server or a new one.

## Demo

Install and use it without buying anything. Until a licence is loaded, one domain can have:

- **10** SIP devices
- **5** contact-center operators

Everything else in the product is available. An expired licence stops the service. No licence does not.

To remove the limits, open **Licences** in the panel, download the request, and send it on Telegram: [t.me/voip_dmitiy](https://t.me/voip_dmitiy). Upload the `licence.json` you receive on the same page.

## Install

A Debian 12 (amd64) server, then one thing you bring yourself: a free [SignalWire](https://signalwire.com) token, which FreeSWITCH uses to download its packages.

```bash
git clone https://github.com/fetchwork/mfdc.git
cd mfdc
unzip -o ui.zip -d ui
sudo TOKEN='your-signalwire-token' bash install.sh
```

`sudo` drops an exported `TOKEN`. Put it on the same line, or the script asks again and an empty answer stops the install.

Point the domain’s DNS A record at the server before you start. The questions are in Russian:

- **Домен** — your public name, for example `pbx.example.com`
- **Выпустить новый сертификат Let's Encrypt сейчас?** — answer `yes`. `no` stops the install: this package does not include a certificate
- **Email** — for certificate expiry notices
- **SIP allow CIDR** — the public IP of your SIP provider, then a blank line. At least one address is required. Phones in the browser use HTTPS and do not belong in this list

When it finishes, sign-in is still locked. In `/opt/mfdc/settings.conf` set `reset_admin_passwd = false`, then:

```bash
sudo systemctl reload mfdc-api
```

Open `https://your-domain/`, sign in as `admin` / `admin`, and change that password. The panel is in English.

SIP itself stays down until you add extensions and a trunk, then:

```bash
sudo systemctl enable --now opensips
```

### SignalWire token

FreeSWITCH packages are published by SignalWire. The account is free. MFDC does not ship the token. Official steps, from the FreeSWITCH manual:

1. Create a SignalWire space at [signalwire.com](https://signalwire.com) and sign in.
2. Open **Personal Access Tokens**: [my.signalwire.com/?page=personal_access_tokens](https://my.signalwire.com/?page=personal_access_tokens).
3. Create a token and copy it. That value is `TOKEN` above.

How SignalWire describes it: [Obtaining a SignalWire Personal Access Token](https://developer.signalwire.com/freeswitch/foundations/getting-started#obtaining-a-signalwire-personal-access-token) in [Chapter 2: Getting Started](https://developer.signalwire.com/freeswitch/foundations/getting-started).

## Update

From the same directory:

```bash
git pull
unzip -o ui.zip -d ui
sudo bash install.sh -update
```

The previous copy is kept in `/opt/mfdc/backup`. Restore it with `sudo bash install.sh -update-rollback`.
