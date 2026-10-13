# MFDC

MFDC is a phone system and contact center you run on your own server. Extensions, SIP trunks, visual call flows, queues, an operator desk in the browser, outbound campaigns, call recordings, and a call history. Download it, install it, and try the demo. No licence file is required.

The panel opens in English. Russian is in the language switch at the top.

## What it does

**Office phones.** Internal numbers on desk phones or in the browser. Calls between staff, transfers from the handset, caller ID, and business hours.

**Trunks.** Connect your SIP provider. Inbound numbers land on a call flow. Outbound calls leave through the route you choose, with your caller ID.

**Call flows.** Draw the call instead of writing a dialplan: greetings, IVR menus, working-hours calendars, conditions, number lists, and connecting the caller to a person, a group, or a queue.

**Contact center.** Queues, an operator panel (ready, pause, answer in the browser), and a supervisor view of who is talking. A supervisor can listen to a live call. Outbound campaigns dial the list and connect answers to free operators.

**History.** Every call is in the journal, with duration, outcome, and the recording when one was made. Export the journal, or send call events to an external CRM.

## Demo

Install and use it without buying anything. Until a licence is loaded, one domain can have:

- **10** SIP devices
- **5** contact-center operators

Everything else in the product is available. An expired licence stops the service. No licence does not.

To remove the limits, open **Licences** in the panel, download the request, and send it on Telegram: [t.me/voip_dmitiy](https://t.me/voip_dmitiy). Upload the `licence.json` you receive on the same page.

## Install

A Debian 12 server, then one thing you bring yourself: a free [SignalWire](https://signalwire.com) token, which FreeSWITCH uses to download its packages.

```bash
git clone https://github.com/fetchwork/mfdc.git
cd mfdc
unzip -o ui.zip -d ui
export TOKEN='your-signalwire-token'
sudo bash install.sh
```

The script asks for your domain name and an email for the certificate, then installs the phone system, the database, and the panel. Open `https://your-domain/` when it finishes.

Point the domain’s DNS A record at the server before you start, so the certificate can be issued.

### SignalWire token

FreeSWITCH packages are published by SignalWire. The account is free. MFDC does not ship the token. Official steps, from the FreeSWITCH manual:

1. Create a SignalWire space at [signalwire.com](https://signalwire.com) and sign in.
2. Open **Personal Access Tokens**: [my.signalwire.com/?page=personal_access_tokens](https://my.signalwire.com/?page=personal_access_tokens).
3. Create a token and copy it. That value is `TOKEN` above.

How SignalWire describes it: [Obtaining a SignalWire Personal Access Token](https://developer.signalwire.com/freeswitch/foundations/getting-started#obtaining-a-signalwire-personal-access-token) in [Chapter 2: Getting Started](https://developer.signalwire.com/freeswitch/foundations/getting-started).

## Update

```bash
git pull
unzip -o ui.zip -d ui
sudo bash install.sh -update
```

The previous copy is kept in `/opt/mfdc/backup`. Restore it with `sudo bash install.sh -update-rollback`.
