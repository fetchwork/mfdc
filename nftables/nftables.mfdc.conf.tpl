#!/usr/sbin/nft -f
# MFDC host firewall (Debian 12 / nftables).
# Default DENY on input. Docker ML binds 127.0.0.1 only — not exposed.
# SSH: allow 22 and 8822 (override via MFDC_SSH_PORTS / install.sh).
# SIP (OpenSIPS 6060/6062, FS 5080/5081) и HTTP/HTTPS/landing (80/443/8008):
#   ONLY from @sip_allow4 / @sip_allow6 (провайдеры + внешние IP офиса).
#   Список: /etc/mfdc/sip_allow.list
# RTP остаётся открытым (медиа от провайдера/абонентов).
# After `nft -f` restart docker + sshguard.

flush ruleset

table inet filter {
	# Разрешённые источники SIP-сигнализации (транки + офис).
	# Placeholders __SIP_ALLOW4__ / __SIP_ALLOW6__ подставляет install.sh.
	set sip_allow4 {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { __SIP_ALLOW4__ }
	}

	set sip_allow6 {
		type ipv6_addr
		flags interval
		auto-merge
		elements = { __SIP_ALLOW6__ }
	}

	chain input {
		type filter hook input priority filter; policy drop;

		iif "lo" accept
		ct state established,related accept
		ct state invalid drop

		# ICMP ping (rate-limited)
		ip protocol icmp icmp type echo-request limit rate 5/second burst 5 packets accept
		ip6 nexthdr icmpv6 icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept

		# SSH — ports substituted by install.sh / reload-sip-allow.sh (__SSH_PORTS__)
		tcp dport { __SSH_PORTS__ } accept

		# UI / WebRTC WSS / landing — только из sip_allow*
		# (nginx :80/:443 → UI + WSS; :8008 — mfdc-landing)
		ip saddr @sip_allow4 tcp dport { 80, 443, 8008 } accept
		ip6 saddr @sip_allow6 tcp dport { 80, 443, 8008 } accept

		# --- SIP signaling: только из sip_allow* ---
		# OpenSIPS (6060/6062) + стандартный SIP 5060 при необходимости
		ip saddr @sip_allow4 udp dport { 5060, 6060, 6062 } accept
		ip saddr @sip_allow4 tcp dport { 5060, 6060 } accept
		ip6 saddr @sip_allow6 udp dport { 5060, 6060, 6062 } accept
		ip6 saddr @sip_allow6 tcp dport { 5060, 6060 } accept
		# FreeSWITCH sofia (если транк бьёт в FS напрямую)
		ip saddr @sip_allow4 udp dport { 5080, 5081 } accept
		ip saddr @sip_allow4 tcp dport { 5080, 5081 } accept
		ip6 saddr @sip_allow6 udp dport { 5080, 5081 } accept
		ip6 saddr @sip_allow6 tcp dport { 5080, 5081 } accept

		# RTP / rtpengine — медиа (ответы на звонки с любых адресов провайдера/абонента)
		udp dport 10000-40000 accept

		counter drop
	}

	chain forward {
		type filter hook forward priority filter; policy drop;
		ct state established,related accept
		iifname "docker0" accept
		oifname "docker0" accept
		iifname "br-*" accept
		oifname "br-*" accept
		iifname "veth*" accept
		oifname "veth*" accept
		counter drop
	}

	chain output {
		type filter hook output priority filter; policy accept;
	}
}
