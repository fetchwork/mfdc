#!/usr/bin/env bash
# MFDC / TelBI — идемпотентная установка на Debian 12 (bookworm) amd64.
#
# НА СЕРВЕРЕ НИЧЕГО НЕ СОБИРАЕТСЯ ИЗ ИСХОДНИКОВ.
# Только: apt-пакеты (FS/PG/OpenSIPS/…) + готовые бинарники из install/bin/
#         + UI из install/ui/ + конфиги.
# Сборка (go/npm) — только на машине разработчика: ./pack.sh или pack.ps1
#
# Повторный запуск безопасен: уже установленное пропускается, новое ставится.
# В начале печатается план (OK / INSTALL / SKIP).
#
#   # на машине сборки:
#   ./pack.sh
#   scp -r install/ root@host:/root/mfdc-install
#   # на сервере (без Go/Node):
#   cd /root/mfdc-install && bash install.sh
#   bash install.sh -update                 # bin/ (+ui/) → /opt/mfdc, бэкап + рестарт при отличии
#   bash install.sh -update-rollback        # восстановить из /opt/mfdc/backup/previous
#
# Переменные:
#   TOKEN=...              SignalWire PAT (нужен только если ставим FreeSWITCH)
#   MFDC_PG_USER=mfdc_admin
#   MFDC_PG_PASS=mfdc_passwd
#   MFDC_PG_DB=mfdc
#   FORCE_CONFIG=1         перезаписать FS/OpenSIPS/nginx/rabbitmq конфиги
#   FORCE_RESTART=1        в конце также стартовать OpenSIPS (иначе он ждёт транков и внутренних номеров).
#                          Остальной стек (PG/Rabbit/FS/rtpengine/nginx/mfdc-*) стартует при установке всегда.
#   SKIP_*=1               пропуск компонента (FREESWITCH, POSTGRES, … DOCKER, ML, FIREWALL)
#   MFDC_DOMAIN=mfdc.example.com  публичный FQDN (nginx/WSS/Let's Encrypt); иначе спросит
#   LE_EMAIL=admin@example.com    email для Let's Encrypt (только если выпускаем новый)
#   LE_ISSUE=1                    без TTY: выпустить новый сертификат certbot'ом
#   LE_ISSUE=0                    без TTY: взять install/cert/fullchain1.pem + privkey1.pem
#                                 (на TTY всегда спрашиваем; «нет» → проверка этих файлов)
#   HTTP_ONLY=1                   без TLS (lab); по умолчанию 0 — HTTPS + LE
#   SKIP_LE=1                     не выпускать сертификат (оставить HTTP)
#   MFDC_PUBLIC_IP=1.2.3.4         внешний IP для rtpengine interface=ex/... (иначе авто/вопрос)
#   MFDC_TIMEZONE=Asia/Almaty      timezone в platform_settings (дефолт UTC)
#   MFDC_SSH_PORTS=auto|22,8822   порты SSH в nftables (auto = SSH_CONNECTION + ss; дефолт auto)
#   SIP_ALLOW=1.2.3.4,10.0.0.0/24  разрешённые SIP-источники (иначе файл/вопрос)
#   SIP_ALLOW_LIST=path           файл со списком CIDR (по умолчанию install/nftables/sip_allow.list)

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPT_MFDC="${OPT_MFDC:-/opt/mfdc}"
UI_WWW="${UI_WWW:-/var/www/mfdc-ui}"
ACME_WWW="${ACME_WWW:-/var/www/certbot}"
MFDC_PG_USER="${MFDC_PG_USER:-mfdc_admin}"
MFDC_PG_PASS="${MFDC_PG_PASS:-mfdc_passwd}"
MFDC_PG_DB="${MFDC_PG_DB:-mfdc}"
MFDC_PG_HOST="${MFDC_PG_HOST:-127.0.0.1}"
MFDC_RABBIT_USER="${MFDC_RABBIT_USER:-mfdc}"
MFDC_RABBIT_PASS="${MFDC_RABBIT_PASS:-mfdc}"
MFDC_DOMAIN="${MFDC_DOMAIN:-}"
MFDC_TIMEZONE="${MFDC_TIMEZONE:-UTC}"
LE_EMAIL="${LE_EMAIL:-}"
LE_ISSUE="${LE_ISSUE:-}"   # пусто = спросить на установке; 1=certbot; 0=install/cert/
HTTP_ONLY="${HTTP_ONLY:-0}"
SKIP_LE="${SKIP_LE:-0}"
FORCE_CONFIG="${FORCE_CONFIG:-0}"
FORCE_RESTART="${FORCE_RESTART:-0}"
MFDC_APP_UPDATE=0
MFDC_UI_UPDATE=0
# Имена бинарников, которые реально заменились в этом запуске (deploy_bin). Нужно рестарту: новый
# mfdc-runner правит структуру БД, и его надо не просто пустить первым, а дождаться (см. restart_mfdc_services).
MFDC_UPDATED_BINS=""
MFDC_UPDATE_MODE=0
MFDC_ROLLBACK_MODE=0
MFDC_AUDIO_FORK_MODE=0
# Реалтайм-форк аудио (docs/audio_fork_plan.md): исходники mod_audio_stream и ссылка на них.
# MFDC_AUDIO_STREAM_REF пустой = ветка по умолчанию; задать тег/коммит, чтобы зафиксировать версию.
MFDC_AUDIO_STREAM_SRC="${MFDC_AUDIO_STREAM_SRC:-/usr/src/mod_audio_stream}"
MFDC_AUDIO_STREAM_REPO="${MFDC_AUDIO_STREAM_REPO:-https://github.com/amigniter/mod_audio_stream.git}"
MFDC_AUDIO_STREAM_REF="${MFDC_AUDIO_STREAM_REF:-}"
# 1 = полная установка: во время apt/конфигов сервисы не стартуем (policy-rc.d + stop).
# В конце start_install_stack поднимает стек, кроме OpenSIPS. Docker/ML — сразу, если ещё не running.
# -update / -update-rollback не трогаем.
MFDC_DEFER_START=0
MFDC_BACKUP_ROOT="${MFDC_BACKUP_ROOT:-${OPT_MFDC}/backup}"
MFDC_BACKUP_KEEP="${MFDC_BACKUP_KEEP:-10}"
MFDC_SSH_PORTS="${MFDC_SSH_PORTS:-auto}"
SIP_ALLOW="${SIP_ALLOW:-}"
SIP_ALLOW_LIST="${SIP_ALLOW_LIST:-}"
ML_DIR="${OPT_MFDC}/ml"
RECORDINGS_DIR="${RECORDINGS_DIR:-/var/lib/freeswitch/recordings/mfdc}"
SOUNDS_DIR="${SOUNDS_DIR:-/var/lib/freeswitch/sounds/mfdc}"
PLAYBACK_URL_BASE="${PLAYBACK_URL_BASE:-http://127.0.0.1:8011/media/play}"
DEBIAN_FRONTEND=noninteractive
export DEBIAN_FRONTEND

# Обязательные готовые бинарники в install/bin/ (linux/amd64). На сервере не собираем.
REQUIRED_BINS=(mfdc-api mfdc-broker mfdc-runner mfdc-caller)
OPTIONAL_BINS=(mfdc-sniffer)

# --- UI helpers --------------------------------------------------------------
C_RESET=$'\033[0m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_DIM=$'\033[2m'

ok()   { echo "  ${C_GREEN}[OK]${C_RESET}      $*"; }
skip() { echo "  ${C_DIM}[SKIP]${C_RESET}    $*"; }
do_it(){ echo "  ${C_CYAN}[INSTALL]${C_RESET} $*"; }
warn() { echo "  ${C_YELLOW}[WARN]${C_RESET}    $*"; }
log()  { echo -e "\n==> $*\n"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: bash install.sh [-update|--update] [-update-rollback|--update-rollback]
                       [-audio-fork-install|--audio-fork-install] [-h|--help]

  (без флагов)          полная идемпотентная установка стека
  -update               обновить bin/ → ${OPT_MFDC} (и ui/ → ${UI_WWW}, если есть);
                        перед заменой — бэкап в ${OPT_MFDC}/backup/<stamp>/;
                        рестарт mfdc-* только если файлы отличаются
  -update-rollback      восстановить бинарники (и UI) из ${OPT_MFDC}/backup/previous
  -audio-fork-install   собрать и поставить mod_audio_stream на ЭТОЙ ноде FreeSWITCH,
                        включить его в конфиге и подписать брокер на события модуля
                        (реалтайм-форк аудио, docs/audio_fork_plan.md); идемпотентно,
                        рассчитано на уже установленную систему
  -h, --help            эта справка

Переменные окружения — см. комментарий в начале install.sh.
  MFDC_BACKUP_KEEP=10      сколько stamp-бэкапов хранить (после бэкапа 11-й самый старый удаляется)
  MFDC_AUDIO_STREAM_REF    тег/коммит mod_audio_stream (пусто = ветка по умолчанию)
  MFDC_AUDIO_STREAM_SRC    куда клонировать исходники (по умолчанию /usr/src/mod_audio_stream)
EOF
}

parse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      -update|--update) MFDC_UPDATE_MODE=1 ;;
      -update-rollback|--update-rollback) MFDC_ROLLBACK_MODE=1 ;;
      -audio-fork-install|--audio-fork-install) MFDC_AUDIO_FORK_MODE=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *)
        die "неизвестный аргумент: $a (см. bash install.sh -h)"
        ;;
    esac
  done
  if (( MFDC_UPDATE_MODE )) && (( MFDC_ROLLBACK_MODE )); then
    die "нельзя вместе -update и -update-rollback"
  fi
  if (( MFDC_AUDIO_FORK_MODE )) && (( MFDC_UPDATE_MODE + MFDC_ROLLBACK_MODE )); then
    die "-audio-fork-install выполняется отдельно от -update / -update-rollback"
  fi
}

# Текст с Windows (CRLF) → Unix LF. mode по умолчанию 0644.
install_lf() {
  local src="$1" dst="$2" mode="${3:-0644}"
  [[ -f "$src" ]] || return 1
  mkdir -p "$(dirname "$dst")"
  tr -d '\r' < "$src" > "$dst"
  chmod "$mode" "$dst"
}

pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

any_pkg_installed() {
  local p
  for p in "$@"; do
    pkg_installed "$p" && return 0
  done
  return 1
}

svc_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

# Пакеты не стартуют сервисы из postinst (иначе RabbitMQ поднимается до нашего NODENAME).
prevent_apt_starts() {
  if [[ -f /usr/sbin/policy-rc.d ]] && ! grep -q 'MFDC install' /usr/sbin/policy-rc.d 2>/dev/null; then
    cp -a /usr/sbin/policy-rc.d /usr/sbin/policy-rc.d.mfdc-bak
  fi
  cat > /usr/sbin/policy-rc.d <<'EOF'
#!/bin/sh
# MFDC install: do not start services from package postinst
exit 101
EOF
  chmod 0755 /usr/sbin/policy-rc.d
}

restore_apt_starts() {
  if [[ -f /usr/sbin/policy-rc.d.mfdc-bak ]]; then
    mv -f /usr/sbin/policy-rc.d.mfdc-bak /usr/sbin/policy-rc.d
  else
    rm -f /usr/sbin/policy-rc.d
  fi
}

ensure_stopped() {
  local unit="$1"
  systemctl cat "${unit}.service" &>/dev/null || return 0
  if svc_active "$unit"; then
    do_it "systemctl stop $unit"
    systemctl stop "$unit" || warn "не удалось stop $unit"
  fi
}

stop_install_stack() {
  local u
  log "установка: останавливаем телефонию/mfdc-* на время пакетов (PostgreSQL не трогаем)"
  for u in freeswitch opensips rabbitmq-server \
           ngcp-rtpengine-daemon rtpengine nginx \
           mfdc-runner mfdc-api mfdc-broker mfdc-caller mfdc-sniffer; do
    ensure_stopped "$u"
  done
}

ensure_postgres_running() {
  if svc_active postgresql || svc_active postgresql@17-main; then
    return 0
  fi
  do_it "systemctl start postgresql"
  systemctl start postgresql 2>/dev/null \
    || systemctl start postgresql@17-main 2>/dev/null || true
  sleep 1
  if svc_active postgresql || svc_active postgresql@17-main; then
    return 0
  fi
  warn "postgresql не стартовал"
  return 1
}

# Во время полной установки не стартуем из середины (conf ещё едет, certbot занимает :80).
# Старт стека — в start_install_stack в конце.
ensure_started() {
  local unit="$1"
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if (( MFDC_DEFER_START )); then
    ensure_stopped "$unit"
    return 0
  fi
  if svc_active "$unit"; then
    ok "$unit уже запущен"
    return 0
  fi
  do_it "systemctl start $unit"
  systemctl start "$unit" || warn "не удалось start $unit"
}

# Старт юнита с отчётом (не валим установку).
start_unit_report() {
  local unit="$1"
  systemctl cat "${unit}.service" &>/dev/null || { skip "$unit — unit нет"; return 0; }
  systemctl enable "$unit" >/dev/null 2>&1 || true
  if svc_active "$unit"; then
    ok "$unit уже active"
    return 0
  fi
  if systemctl start "$unit" 2>/dev/null && svc_active "$unit"; then
    ok "$unit active"
    return 0
  fi
  warn "$unit НЕ active — journalctl -u $unit"
}

files_same() {
  local src="$1" dst="$2"
  [[ -f "$src" && -f "$dst" ]] || return 1
  cmp -s "$src" "$dst"
}

# index.html обязан указывать на JS/CSS, которые лежат в том же дереве. Иначе
# rsync --delete снимет рабочий /var/www/mfdc-ui и браузер получит HTML вместо чанков
# (Expected a JavaScript module … MIME type of text/html).
ui_dist_complete() {
  local dir="$1" js css
  [[ -f "${dir}/index.html" && -d "${dir}/assets" ]] || return 1
  js="$(grep -oE '/assets/index-[A-Za-z0-9._-]+\.js' "${dir}/index.html" | head -1)"
  css="$(grep -oE '/assets/index-[A-Za-z0-9._-]+\.css' "${dir}/index.html" | head -1)"
  [[ -n "$js" && -f "${dir}${js}" ]] || return 1
  [[ -z "$css" || -f "${dir}${css}" ]]
}

# 0 = деревья отличаются (нужно обновление), 1 = одинаковы
ui_tree_differs() {
  local src="$1" dst="$2"
  local delta=""
  [[ -d "$src" && -f "${src}/index.html" ]] || return 1
  [[ -d "$dst" && -f "${dst}/index.html" ]] || return 0
  if command -v rsync >/dev/null 2>&1; then
    # dry-run itemize: любой вывод = есть отличия (pipefail-safe)
    delta="$(rsync -ani --delete "${src}/" "${dst}/" 2>/dev/null | head -c 1 || true)"
    [[ -n "$delta" ]]
  else
    ! diff -rq "$src" "$dst" >/dev/null 2>&1
  fi
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "запустите от root: sudo bash install.sh"
}

bundled_le_cert_dir() {
  echo "${INSTALL_DIR}/cert"
}

has_bundled_le_certs() {
  local d
  d="$(bundled_le_cert_dir)"
  [[ -s "${d}/fullchain1.pem" && -s "${d}/privkey1.pem" ]]
}

# Спросить, выпускать ли новый LE-сертификат (только полная установка, не -update).
# Вопрос всегда. «Нет» → тогда проверяем install/cert/fullchain1.pem + privkey1.pem.
# LE_ISSUE=0|1 — только без TTY (без вопроса).
prompt_letsencrypt_issue() {
  local ans
  if [[ ! -t 0 ]]; then
    [[ "${LE_ISSUE}" == "1" || "${LE_ISSUE}" == "0" ]] || \
      die "нет TTY — задайте LE_ISSUE=1 (новый Let's Encrypt) или LE_ISSUE=0 (файлы из install/cert/)"
    ok "Let's Encrypt: LE_ISSUE=${LE_ISSUE} (нет TTY)"
    return
  fi

  echo
  echo "Сертификат HTTPS для ${MFDC_DOMAIN}."
  while true; do
    read -r -p "Выпустить новый сертификат Let's Encrypt сейчас? [да/нет]: " ans
    echo
    ans="$(echo "${ans}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    case "${ans}" in
      y|yes|д|да|1) LE_ISSUE=1; return ;;
      n|no|н|нет|0) LE_ISSUE=0; return ;;
    esac
    echo "Ответьте да или нет."
  done
}

# Спросить публичный FQDN для nginx / WSS / Let's Encrypt.
prompt_public_domain() {
  if [[ "${HTTP_ONLY}" == "1" ]] || [[ "${SKIP_LE}" == "1" ]]; then
    if [[ -z "${MFDC_DOMAIN}" ]]; then
      MFDC_DOMAIN="$(hostname -f 2>/dev/null || hostname)"
    fi
    ok "домен для nginx: ${MFDC_DOMAIN} (HTTP_ONLY/SKIP_LE — без Let's Encrypt)"
    return
  fi

  if [[ -z "${MFDC_DOMAIN}" ]]; then
    echo
    echo "Нужен публичный DNS-домен, который указывает на этот сервер (A/AAAA)."
    echo "По нему будут: HTTPS UI, WSS (WebRTC) и сертификат Let's Encrypt."
    read -r -p "Домен (например mfdc.company.com): " MFDC_DOMAIN
    echo
  fi
  MFDC_DOMAIN="$(echo "${MFDC_DOMAIN}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  [[ -n "${MFDC_DOMAIN}" ]] || die "домен не задан (MFDC_DOMAIN=... или ввод)"
  if [[ ! "${MFDC_DOMAIN}" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    die "некорректный домен: ${MFDC_DOMAIN}"
  fi

  prompt_letsencrypt_issue

  if [[ "${LE_ISSUE}" == "0" ]]; then
    has_bundled_le_certs || die "LE_ISSUE=0, но нет $(bundled_le_cert_dir)/fullchain1.pem и privkey1.pem
Скопируйте их из /etc/letsencrypt/archive/<домен>/ на машине, где сертификат уже выпускали."
    ok "домен: ${MFDC_DOMAIN}"
    ok "TLS: готовые файлы из install/cert/ → /etc/letsencrypt/live/${MFDC_DOMAIN}/"
    ok "WSS будет: wss://${MFDC_DOMAIN}/wss/"
    return
  fi

  if [[ -z "${LE_EMAIL}" ]]; then
    read -r -p "Email для Let's Encrypt (уведомления о сроке сертификата): " LE_EMAIL
    echo
  fi
  LE_EMAIL="$(echo "${LE_EMAIL}" | tr -d '[:space:]')"
  [[ -n "${LE_EMAIL}" ]] || die "нужен LE_EMAIL для Let's Encrypt"

  ok "домен: ${MFDC_DOMAIN}"
  ok "Let's Encrypt email: ${LE_EMAIL}"
  ok "WSS будет: wss://${MFDC_DOMAIN}/wss/"
}

require_amd64() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    die "нужен amd64/x86_64 (бинарники в bin/ собраны под linux/amd64), сейчас: $arch"
  fi
  ok "архитектура $arch"
}

# Готовые артефакты пакета: без Go/npm на сервере.
require_prebuilt_artifacts() {
  [[ "${SKIP_MFDC:-0}" == "1" ]] && return 0

  local bin_dir="${INSTALL_DIR}/bin"
  local missing=()
  local name

  [[ -d "$bin_dir" ]] || die "нет ${bin_dir}/ — скопируйте пакет после pack.sh (на сервере бинарники не собираются)"

  for name in "${REQUIRED_BINS[@]}"; do
    if [[ ! -f "${bin_dir}/${name}" ]] || [[ ! -s "${bin_dir}/${name}" ]]; then
      missing+=("$name")
    fi
  done

  if ((${#missing[@]})); then
    die "в ${bin_dir}/ нет готовых бинарников: ${missing[*]}
На машине сборки: ./pack.sh или pack.ps1
На сервер копируйте весь каталог install/ с уже собранными bin/ и ui/.
На сервере go build / npm НЕ запускаются."
  fi

  for name in "${REQUIRED_BINS[@]}"; do
    chmod +x "${bin_dir}/${name}" 2>/dev/null || true
    ok "готовый бинарник bin/${name} ($(du -h "${bin_dir}/${name}" | awk '{print $1}'))"
  done
  for name in "${OPTIONAL_BINS[@]}"; do
    if [[ -f "${bin_dir}/${name}" ]]; then
      chmod +x "${bin_dir}/${name}" 2>/dev/null || true
      ok "опциональный bin/${name}"
    else
      skip "опциональный bin/${name} отсутствует"
    fi
  done

  if [[ -f "${INSTALL_DIR}/ui/index.html" ]]; then
    ok "готовый UI install/ui/"
  else
    die "нет install/ui/index.html — сначала pack.sh / pack.ps1 на машине сборки"
  fi

  if [[ ! -d "${INSTALL_DIR}/freeswitch" ]] || [[ ! -f "${INSTALL_DIR}/freeswitch/freeswitch.xml" ]]; then
    die "нет install/freeswitch/ — пакет неполный (нужен pack.sh)"
  fi
  ok "конфиги FreeSWITCH в пакете"

  if [[ ! -f "${INSTALL_DIR}/opensips/opensips.cfg" ]]; then
    die "нет install/opensips/opensips.cfg — пакет неполный (нужен pack.sh)"
  fi
  ok "opensips.cfg в пакете"

  [[ -f "${INSTALL_DIR}/rabbitmq/rabbitmq.conf" ]] || die "нет install/rabbitmq/rabbitmq.conf"
  [[ -f "${INSTALL_DIR}/nginx/mfdc-ui-http.conf" ]] || die "нет install/nginx/mfdc-ui-http.conf"
  [[ -f "${INSTALL_DIR}/settings.conf" ]] || die "нет install/settings.conf"
  ok "rabbitmq / nginx / settings.conf в пакете"

  if [[ -f "${INSTALL_DIR}/public.key" ]] || [[ -f "${INSTALL_DIR}/licence/public.key" ]]; then
    ok "public.key в пакете (проверка лицензий)"
  else
    warn "нет install/public.key — положите Ed25519 public key продавца в корень install/"
  fi
}

# --- Plan (что будет сделано) ------------------------------------------------
print_plan() {
  log "план установки (идемпотентно, без сборки Go/npm из исходников)"

  if [[ "${HTTP_ONLY}" == "1" ]] || [[ "${SKIP_LE}" == "1" ]]; then
    skip "Let's Encrypt (HTTP_ONLY/SKIP_LE) — домен ${MFDC_DOMAIN:-?}"
  elif [[ "${LE_ISSUE}" == "0" ]]; then
    do_it "домен ${MFDC_DOMAIN:-?} → nginx HTTPS + WSS, сертификат из install/cert/"
  else
    do_it "домен ${MFDC_DOMAIN:-?} → nginx HTTPS + WSS + Let's Encrypt (${LE_EMAIL:-email?})"
  fi

  if [[ "${SKIP_FREESWITCH:-0}" == "1" ]]; then
    skip "FreeSWITCH (SKIP_FREESWITCH=1)"
  elif pkg_installed freeswitch; then
    ok "FreeSWITCH уже установлен ($(freeswitch -version 2>/dev/null | head -1 || echo ok))"
  else
    do_it "FreeSWITCH + модули (apt, нужен TOKEN)"
  fi

  if [[ "${SKIP_POSTGRES:-0}" == "1" ]]; then
    skip "PostgreSQL (SKIP_POSTGRES=1)"
  elif pkg_installed postgresql-17; then
    ok "PostgreSQL 17 уже установлен — проверим роль ${MFDC_PG_USER} / БД ${MFDC_PG_DB} / права + тюнинг conf"
  elif any_pkg_installed postgresql postgresql-16 postgresql-15 postgresql-14; then
    ok "PostgreSQL уже есть — проверим роль ${MFDC_PG_USER} / БД ${MFDC_PG_DB} / права + тюнинг conf"
  else
    do_it "PostgreSQL 17 + роль ${MFDC_PG_USER} / БД ${MFDC_PG_DB} + тюнинг conf"
  fi

  if [[ "${SKIP_OPENSIPS:-0}" == "1" ]]; then
    skip "OpenSIPS (SKIP_OPENSIPS=1)"
  elif pkg_installed opensips; then
    ok "OpenSIPS уже установлен"
  else
    do_it "OpenSIPS 3.6 + модули (apt)"
  fi

  if [[ "${SKIP_RABBITMQ:-0}" == "1" ]]; then
    skip "RabbitMQ (SKIP_RABBITMQ=1)"
  elif pkg_installed rabbitmq-server; then
    ok "RabbitMQ уже установлен — конфиг не трогаем, проверим user ${MFDC_RABBIT_USER}"
  else
    do_it "RabbitMQ + user ${MFDC_RABBIT_USER} (apt)"
  fi

  if [[ "${SKIP_RTPENGINE:-0}" == "1" ]]; then
    skip "rtpengine (SKIP_RTPENGINE=1)"
  elif any_pkg_installed ngcp-rtpengine ngcp-rtpengine-daemon rtpengine; then
    ok "rtpengine уже установлен"
  else
    do_it "ngcp-rtpengine (apt)"
  fi

  if [[ "${SKIP_MFDC:-0}" == "1" ]]; then
    skip "MFDC apps (SKIP_MFDC=1)"
  else
    do_it "bin/ → ${OPT_MFDC}, ui/ → ${UI_WWW} (рестарт mfdc-* только если отличаются)"
  fi

  if [[ "${SKIP_DOCKER:-0}" == "1" ]]; then
    skip "Docker (SKIP_DOCKER=1)"
  elif command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен"
  else
    do_it "Docker Engine (apt)"
  fi

  if [[ "${SKIP_ML:-0}" == "1" ]]; then
    skip "ML containers (SKIP_ML=1)"
  elif [[ -d "${INSTALL_DIR}/ml/whisper" ]]; then
    do_it "mfdc-whisper + mfdc-topic-classifier (compose up, если ещё не running)"
  else
    warn "нет install/ml/ — ML sidecar не ставятся"
  fi

  if [[ "${SKIP_FIREWALL:-0}" == "1" ]]; then
    skip "nftables (SKIP_FIREWALL=1)"
  else
    do_it "nftables firewall (SSH ${MFDC_SSH_PORTS}; SIP только из allow-list)"
  fi

  if [[ "${SKIP_SSHGUARD:-0}" == "1" ]] || [[ "${SKIP_FIREWALL:-0}" == "1" ]]; then
    skip "sshguard (SKIP_SSHGUARD/SKIP_FIREWALL)"
  elif pkg_installed sshguard; then
    ok "sshguard уже установлен — проверим nft backend"
  else
    do_it "sshguard (anti-bruteforce SSH, nft-sets)"
  fi

  if [[ "$FORCE_CONFIG" == "1" ]]; then
    warn "FORCE_CONFIG=1 — конфиги FS/OpenSIPS/nginx/rabbitmq будут перезаписаны"
  fi
  do_it "в конце: postgresql rabbitmq freeswitch rtpengine nginx mfdc-* (кроме OpenSIPS)"
  skip "OpenSIPS не стартуем — после транков и внутренних номеров: systemctl enable --now opensips"
  echo
}

# --- Base --------------------------------------------------------------------
require_bookworm() {
  if ! command -v lsb_release >/dev/null 2>&1; then
    do_it "lsb-release"
    apt-get update -qq
    apt-get install -y -qq lsb-release
  fi
  local codename
  codename="$(lsb_release -cs)"
  if [[ "$codename" != "bookworm" ]]; then
    warn "ожидается Debian bookworm, сейчас: $codename (продолжаем)"
  else
    ok "Debian bookworm"
  fi
}

ensure_hostname_loopback() {
  local hn short
  hn="$(hostname -f 2>/dev/null || hostname)"
  short="$(hostname -s 2>/dev/null || hostname)"
  host_on_loopback() {
    getent hosts "$1" 2>/dev/null | grep -qE '127\.0\.0\.1|127\.0\.1\.1|::1'
  }
  # RabbitMQ/epmd резолвят короткое имя, не FQDN. Публичный A-запись FQDN не спасает.
  if host_on_loopback "$short" && { [[ "$hn" == "$short" ]] || host_on_loopback "$hn"; }; then
    ok "hostname $short резолвится на loopback"
    return
  fi
  do_it "hostname $short ($hn) → 127.0.0.1 в /etc/hosts (RabbitMQ/epmd)"
  if grep -qE '^127\.0\.0\.1[[:space:]]' /etc/hosts; then
    local line
    line="$(grep -E '^127\.0\.0\.1[[:space:]]' /etc/hosts | head -1)"
    echo "$line" | grep -qw "$short" || sed -i -E "0,/^127\\.0\\.0\\.1[[:space:]]/s//&${short} /" /etc/hosts
    if [[ "$hn" != "$short" ]]; then
      echo "$line" | grep -qw "$hn" || sed -i -E "0,/^127\\.0\\.0\\.1[[:space:]]/s//&${hn} /" /etc/hosts
    fi
  else
    echo "127.0.0.1 localhost ${short} ${hn}" >> /etc/hosts
  fi
}

apt_base() {
  local need=()
  local p
  for p in curl ca-certificates gnupg gnupg2 wget lsb-release apt-transport-https \
           software-properties-common sudo nginx; do
    pkg_installed "$p" || need+=("$p")
  done
  if ((${#need[@]})); then
    do_it "базовые пакеты: ${need[*]}"
    apt-get update -qq
    apt-get install -y -qq "${need[@]}"
  else
    ok "базовые пакеты уже установлены"
  fi
}

# --- FreeSWITCH --------------------------------------------------------------
install_freeswitch() {
  [[ "${SKIP_FREESWITCH:-0}" == "1" ]] && { skip "FreeSWITCH"; return; }

  if pkg_installed freeswitch; then
    ok "FreeSWITCH уже установлен"
    # доустановить недостающие модули без полного reinstall
    local missing=()
    local m
    for m in freeswitch-mod-xml-curl freeswitch-mod-curl freeswitch-mod-amqp \
             freeswitch-mod-event-socket freeswitch-mod-sofia freeswitch-mod-lua; do
      pkg_installed "$m" || missing+=("$m")
    done
    if ((${#missing[@]})); then
      do_it "модули FreeSWITCH: ${missing[*]}"
      apt-get install -qqy --no-install-recommends "${missing[@]}" || warn "не все модули поставились"
    else
      ok "ключевые модули FreeSWITCH на месте"
    fi
    if [[ -f /etc/freeswitch/.mfdc-installed ]]; then
      ensure_stopped freeswitch
    else
      ok "FreeSWITCH уже установлен — конфиги без старта"
    fi
    ensure_freeswitch_logging
    return
  fi

  do_it "FreeSWITCH (SignalWire repo)"
  if [[ -z "${TOKEN:-}" ]]; then
    read -r -p "SignalWire FreeSWITCH token (PAT): " TOKEN
    echo
  fi
  [[ -n "${TOKEN:-}" ]] || die "нужен TOKEN для репозитория FreeSWITCH"

  if [[ ! -f /usr/share/keyrings/signalwire-freeswitch-repo.gpg ]]; then
    do_it "ключ SignalWire apt"
    wget --http-user=signalwire --http-password="$TOKEN" \
      -O /usr/share/keyrings/signalwire-freeswitch-repo.gpg \
      https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg
  else
    ok "ключ SignalWire уже есть"
  fi

  mkdir -p /etc/apt/auth.conf.d
  echo "machine freeswitch.signalwire.com login signalwire password $TOKEN" \
    > /etc/apt/auth.conf.d/freeswitch.conf
  chmod 600 /etc/apt/auth.conf.d/freeswitch.conf

  if [[ ! -f /etc/apt/sources.list.d/freeswitch.list ]]; then
    do_it "apt source freeswitch"
    echo "deb [signed-by=/usr/share/keyrings/signalwire-freeswitch-repo.gpg] https://freeswitch.signalwire.com/repo/deb/debian-release/ $(lsb_release -sc) main" \
      > /etc/apt/sources.list.d/freeswitch.list
  else
    ok "apt source freeswitch уже есть"
  fi

  apt-get update -qq
  do_it "пакеты FreeSWITCH"
  apt-get install -qqy --no-install-recommends imagemagick librabbitmq4 ffmpeg \
    freeswitch freeswitch-mod-av freeswitch-mod-opus freeswitch-mod-sndfile \
    freeswitch-mod-shout freeswitch-mod-sofia freeswitch-mod-dialplan-xml \
    freeswitch-mod-valet-parking freeswitch-mod-conference freeswitch-mod-opusfile \
    freeswitch-mod-console freeswitch-mod-event-socket freeswitch-mod-loopback \
    freeswitch-mod-commands freeswitch-mod-db freeswitch-mod-dptools \
    freeswitch-mod-expr freeswitch-mod-hash freeswitch-mod-spandsp \
    freeswitch-mod-imagick freeswitch-mod-png freeswitch-mod-native-file \
    freeswitch-mod-local-stream freeswitch-mod-tone-stream freeswitch-mod-lua \
    freeswitch-mod-http-cache freeswitch-mod-spy freeswitch-music-default \
    freeswitch-mod-json-cdr freeswitch-mod-logfile freeswitch-systemd \
    freeswitch-mod-say-ru freeswitch-mod-say-en \
    freeswitch-mod-xml-rpc freeswitch-mod-xml-curl freeswitch-mod-curl

  if ! apt-get install -qqy --no-install-recommends freeswitch-mod-amqp; then
    warn "freeswitch-mod-amqp не установлен — события в RabbitMQ не пойдут"
  fi
  systemctl enable freeswitch >/dev/null 2>&1 || true
  ensure_stopped freeswitch
  ok "FreeSWITCH установлен (сервис не запускаем)"
  ensure_freeswitch_logging
}

deploy_freeswitch_conf() {
  [[ "${SKIP_FREESWITCH:-0}" == "1" ]] && return
  local src="${INSTALL_DIR}/freeswitch"
  [[ -d "$src" ]] || { warn "нет $src — конфиги FS не скопированы"; return; }

  if [[ -f /etc/freeswitch/freeswitch.xml ]] && [[ "$FORCE_CONFIG" != "1" ]]; then
    # считаем «уже настроено», если наш marker или configuration.xml совпадает
    if [[ -f /etc/freeswitch/configuration.xml ]] && files_same "$src/configuration.xml" /etc/freeswitch/configuration.xml; then
      ok "конфиги FreeSWITCH уже актуальны"
      ensure_freeswitch_logging
      apply_freeswitch_install_vars
      return
    fi
    if [[ -f /etc/freeswitch/.mfdc-installed ]] && [[ "$FORCE_CONFIG" != "1" ]]; then
      ok "конфиги FreeSWITCH уже развёрнуты (FORCE_CONFIG=1 чтобы перезаписать)"
      ensure_freeswitch_logging
      apply_freeswitch_install_vars
      return
    fi
    # есть vanilla/чужой конфиг — бэкап и ставим наши
    warn "обнаружен /etc/freeswitch — бэкап и установка MFDC-конфигов"
  fi

  do_it "конфиги FreeSWITCH → /etc/freeswitch"
  mkdir -p /etc/freeswitch
  if [[ -f /etc/freeswitch/freeswitch.xml ]] && [[ ! -d /etc/freeswitch.mfdc-bak ]]; then
    cp -a /etc/freeswitch /etc/freeswitch.mfdc-bak
  fi
  cp -a "$src/." /etc/freeswitch/
  if [[ -d "$src/lua" ]]; then
    mkdir -p /usr/share/freeswitch/scripts
    cp -a "$src/lua/." /usr/share/freeswitch/scripts/
  fi
  touch /etc/freeswitch/.mfdc-installed
  chown -R freeswitch:freeswitch /etc/freeswitch 2>/dev/null || true
  ensure_stopped freeswitch
  ensure_freeswitch_logging
  # Пакет несёт плейсхолдер __MFDC_API_KEY__ — сразу подставить сгенерированный api.key.
  apply_freeswitch_install_vars
}

# --- PostgreSQL --------------------------------------------------------------
find_postgresql_conf() {
  local f
  for f in /etc/postgresql/17/main/postgresql.conf \
           /etc/postgresql/16/main/postgresql.conf \
           /etc/postgresql/15/main/postgresql.conf \
           /etc/postgresql/14/main/postgresql.conf; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  f="$(sudo -u postgres psql -tAc "SHOW config_file" 2>/dev/null | tr -d '[:space:]' || true)"
  [[ -n "$f" && -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  return 1
}

# Раскомментировать/задать ключ в postgresql.conf. 0=изменили, 1=уже так.
pg_conf_set() {
  local conf="$1" key="$2" val="$3"
  local cur want line
  # pipefail: grep без совпадений = exit 1 — не роняем install
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$conf" 2>/dev/null | tail -1 || true)"
  cur="$(printf '%s' "$line" \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
    | sed -E 's/[[:space:]]*(#.*)?$//' \
    | tr -d '[:space:]')"
  want="$(printf '%s' "$val" | tr -d '[:space:]')"
  if [[ -n "$cur" && "$cur" == "$want" ]]; then
    return 1
  fi
  if grep -qE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$conf"; then
    # только первая (активная или закомментированная) строка — не плодим дубликаты
    sed -i -E "0,/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*/s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$conf"
  else
    printf '\n# MFDC tuning\n%s = %s\n' "$key" "$val" >> "$conf"
  fi
  return 0
}

# Тюнинг /etc/postgresql/17/main/postgresql.conf (или другой найденный major).
tune_postgresql_conf() {
  local conf changed=0
  conf="$(find_postgresql_conf 2>/dev/null || true)"
  if [[ -z "$conf" || ! -f "$conf" ]]; then
    warn "postgresql.conf не найден — тюнинг пропущен"
    return 0
  fi

  do_it "тюнинг PostgreSQL → ${conf}"
  cp -a "$conf" "${conf}.mfdc-bak" 2>/dev/null || true

  pg_conf_set "$conf" listen_addresses "'localhost'" && changed=1 || true
  pg_conf_set "$conf" max_connections "150" && changed=1 || true
  pg_conf_set "$conf" shared_buffers "512MB" && changed=1 || true
  pg_conf_set "$conf" work_mem "5MB" && changed=1 || true
  pg_conf_set "$conf" maintenance_work_mem "512MB" && changed=1 || true
  pg_conf_set "$conf" effective_io_concurrency "256" && changed=1 || true
  pg_conf_set "$conf" checkpoint_completion_target "0.9" && changed=1 || true
  pg_conf_set "$conf" random_page_cost "1.1" && changed=1 || true

  if ((changed)); then
    do_it "systemctl restart postgresql (новые параметры conf)"
    systemctl restart postgresql 2>/dev/null \
      || systemctl restart postgresql@17-main 2>/dev/null \
      || warn "restart postgresql failed — проверьте ${conf}"
    sleep 1
    ok "PostgreSQL conf обновлён (listen=localhost, max_conn=150, shared_buffers=512MB, …)"
  else
    ok "PostgreSQL conf уже с нужным тюнингом"
  fi
}

ensure_pg_role_and_db() {
  # Идемпотентно даже если PostgreSQL уже стоял:
  #  - роль mfdc_admin (LOGIN + пароль)
  #  - БД mfdc (OWNER = mfdc_admin)
  #  - полные права на БД и schema public (+ default privileges на будущие объекты)
  if ! command -v psql >/dev/null 2>&1; then
    warn "psql не найден — роль/БД не созданы"
    return 0
  fi
  if ! svc_active postgresql && ! svc_active postgresql@17-main; then
    do_it "временный старт postgresql (создание роли/БД)"
    systemctl start postgresql 2>/dev/null \
      || systemctl start postgresql@17-main 2>/dev/null || true
    sleep 1
  fi

  local role_exists db_exists db_owner
  role_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${MFDC_PG_USER}'" 2>/dev/null | tr -d '[:space:]' || true)"
  db_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${MFDC_PG_DB}'" 2>/dev/null | tr -d '[:space:]' || true)"
  db_owner="$(sudo -u postgres psql -tAc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${MFDC_PG_DB}'" 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ "$role_exists" == "1" ]]; then
    ok "роль ${MFDC_PG_USER} уже есть — синхронизируем пароль/атрибуты"
  else
    do_it "создание роли ${MFDC_PG_USER}"
  fi
  if [[ "$db_exists" == "1" ]]; then
    ok "БД ${MFDC_PG_DB} уже есть (owner=${db_owner:-?})"
  else
    do_it "создание БД ${MFDC_PG_DB}"
  fi

  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${MFDC_PG_USER}') THEN
    CREATE ROLE ${MFDC_PG_USER} LOGIN PASSWORD '${MFDC_PG_PASS}';
  ELSE
    ALTER ROLE ${MFDC_PG_USER} WITH LOGIN PASSWORD '${MFDC_PG_PASS}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${MFDC_PG_DB} OWNER ${MFDC_PG_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${MFDC_PG_DB}')\gexec
-- если БД уже была с другим владельцем — передаём mfdc_admin
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_database WHERE datname = '${MFDC_PG_DB}') THEN
    EXECUTE format('ALTER DATABASE %I OWNER TO %I', '${MFDC_PG_DB}', '${MFDC_PG_USER}');
  END IF;
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE ${MFDC_PG_DB} TO ${MFDC_PG_USER};
GRANT CONNECT, TEMPORARY, CREATE ON DATABASE ${MFDC_PG_DB} TO ${MFDC_PG_USER};
-- Восстановление конфигурации (Настройки → Резервные копии) выполняет
-- SET LOCAL session_replication_role = replica, чтобы обойти FK/триггеры на время заливки.
-- Это право суперпользователя; с PG 15 его можно выдать точечно, без SUPERUSER для роли.
-- Без него restore падает с "permission denied to set parameter session_replication_role".
DO \$\$
BEGIN
  IF current_setting('server_version_num')::int >= 150000 THEN
    EXECUTE format('GRANT SET ON PARAMETER session_replication_role TO %I', '${MFDC_PG_USER}');
  END IF;
END
\$\$;
SQL

  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${MFDC_PG_DB}" <<SQL
GRANT ALL ON SCHEMA public TO ${MFDC_PG_USER};
ALTER SCHEMA public OWNER TO ${MFDC_PG_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${MFDC_PG_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${MFDC_PG_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${MFDC_PG_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${MFDC_PG_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${MFDC_PG_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${MFDC_PG_USER};
-- право создавать схемы (bootstrap mfdc-runner: broker, auth, …)
GRANT CREATE ON DATABASE ${MFDC_PG_DB} TO ${MFDC_PG_USER};
SQL

  # Проверка факта: роль, БД, owner, connect под паролем
  role_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${MFDC_PG_USER}' AND rolcanlogin" | tr -d '[:space:]')"
  db_exists="$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${MFDC_PG_DB}'" | tr -d '[:space:]')"
  db_owner="$(sudo -u postgres psql -tAc "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${MFDC_PG_DB}'" | tr -d '[:space:]')"
  local can_create
  can_create="$(sudo -u postgres psql -tAc "SELECT has_database_privilege('${MFDC_PG_USER}', '${MFDC_PG_DB}', 'CREATE')" | tr -d '[:space:]')"

  [[ "$role_exists" == "1" ]] || die "после ensure: нет LOGIN-роли ${MFDC_PG_USER}"
  [[ "$db_exists" == "1" ]] || die "после ensure: нет БД ${MFDC_PG_DB}"
  [[ "$db_owner" == "${MFDC_PG_USER}" ]] || die "после ensure: owner БД ${MFDC_PG_DB} = '${db_owner}', ожидался ${MFDC_PG_USER}"
  [[ "$can_create" == "t" ]] || die "после ensure: у ${MFDC_PG_USER} нет CREATE на БД ${MFDC_PG_DB}"

  if PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc "SELECT 1" 2>/dev/null | grep -q 1; then
    ok "подключение ${MFDC_PG_USER}@${MFDC_PG_DB} (пароль OK, полные права)"
  else
    warn "TCP-логин не прошёл — правим pg_hba для 127.0.0.1"
    ensure_pg_hba_password_local
    if PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc "SELECT 1" 2>/dev/null | grep -q 1; then
      ok "подключение ${MFDC_PG_USER}@${MFDC_PG_DB} после pg_hba OK"
    else
      warn "TCP-логин всё ещё не проходит — проверьте pg_hba.conf / listen_addresses вручную"
      ok "роль/БД/права в каталоге PostgreSQL в порядке (owner=${db_owner}, CREATE=yes)"
    fi
  fi
}

# Разрешить password-auth с localhost (нужно сервисам MFDC по TCP).
ensure_pg_hba_password_local() {
  local hba
  hba="$(sudo -u postgres psql -tAc "SHOW hba_file" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$hba" && -f "$hba" ]] || { warn "не найден hba_file"; return 0; }
  if grep -qE "^[[:space:]]*host[[:space:]]+${MFDC_PG_DB}[[:space:]]+${MFDC_PG_USER}[[:space:]]+127\.0\.0\.1/32" "$hba"; then
    ok "pg_hba: правило для ${MFDC_PG_USER}@127.0.0.1 уже есть"
  else
    do_it "pg_hba: host ${MFDC_PG_DB} ${MFDC_PG_USER} 127.0.0.1/32 scram-sha-256"
    # вставить перед первой строкой host/local all — в начало секции host
    cp -a "$hba" "${hba}.mfdc-bak"
    {
      echo "# MFDC — TCP auth for app user"
      echo "host    ${MFDC_PG_DB}    ${MFDC_PG_USER}    127.0.0.1/32    scram-sha-256"
      echo "host    ${MFDC_PG_DB}    ${MFDC_PG_USER}    ::1/128         scram-sha-256"
      cat "$hba"
    } > "${hba}.mfdc-new"
    mv "${hba}.mfdc-new" "$hba"
    chown postgres:postgres "$hba"
    chmod 640 "$hba"
  fi
  sudo -u postgres psql -c "SELECT pg_reload_conf()" >/dev/null || systemctl reload postgresql || true
}

install_postgres() {
  [[ "${SKIP_POSTGRES:-0}" == "1" ]] && { skip "PostgreSQL"; return; }

  if pkg_installed postgresql-17; then
    ok "PostgreSQL 17 уже установлен — проверяем БД/роль/права"
  elif any_pkg_installed postgresql postgresql-16 postgresql-15 postgresql-14; then
    warn "установлен PostgreSQL не 17-й — используем существующий, проверяем БД/роль/права"
  else
    do_it "PostgreSQL 17 (PGDG)"
    if [[ ! -f /usr/share/keyrings/postgresql-archive-keyring.gpg ]]; then
      curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
    fi
    if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
      echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list
    fi
    apt-get update -qq
    apt-get install -y postgresql-17 postgresql-client-17
  fi

  systemctl enable postgresql >/dev/null 2>&1 || true
  tune_postgresql_conf
  ensure_postgres_running || warn "postgresql не running — роль/БД могут не создаться"
  ensure_pg_role_and_db
}

# --- OpenSIPS ----------------------------------------------------------------
ensure_opensips_repo() {
  if [[ ! -f /usr/share/keyrings/opensips-org.gpg ]]; then
    curl -fsSL https://apt.opensips.org/opensips-org.gpg -o /usr/share/keyrings/opensips-org.gpg
  fi
  local list=/etc/apt/sources.list.d/opensips.list
  local want='deb [signed-by=/usr/share/keyrings/opensips-org.gpg] https://apt.opensips.org bookworm 3.6-releases cli-nightly'
  # opensips-cli живёт только в cli-nightly (не в 3.6-releases)
  if [[ ! -f "$list" ]] || ! grep -qE 'cli-nightly' "$list" 2>/dev/null; then
    echo "$want" > "$list"
    apt-get update -qq
  fi
}

# opensips-cli ставится отдельно: при «opensips уже есть» раньше install выходил и cli не ставился.
ensure_opensips_cli() {
  if command -v opensips-cli >/dev/null 2>&1 || pkg_installed opensips-cli; then
    ok "opensips-cli уже установлен ($(command -v opensips-cli 2>/dev/null || echo ok))"
    return
  fi
  ensure_opensips_repo
  do_it "opensips-cli"
  apt-get update -qq
  apt-get install -y opensips-cli \
    || warn "opensips-cli не установился — проверьте apt.opensips.org / apt-cache policy opensips-cli"
  if command -v opensips-cli >/dev/null 2>&1; then
    ok "opensips-cli: $(opensips-cli -V 2>/dev/null | head -1 || command -v opensips-cli)"
  fi
}

install_opensips() {
  [[ "${SKIP_OPENSIPS:-0}" == "1" ]] && { skip "OpenSIPS"; return; }

  if pkg_installed opensips; then
    ok "OpenSIPS уже установлен ($(opensips -V 2>/dev/null | head -1 || true))"
    ensure_opensips_cli
    # Старт — только после транков и внутренних номеров (start_install_stack / FORCE_RESTART).
    if [[ -f /etc/opensips/.mfdc-installed ]]; then
      ok "opensips: MFDC cfg на месте — не запускаем"
    fi
    systemctl disable --now opensips >/dev/null 2>&1 || true
    ensure_stopped opensips
    return
  fi

  do_it "OpenSIPS 3.6"
  ensure_opensips_repo
  apt-get update -qq
  apt-get install -y opensips opensips-cli \
    opensips-auth-modules opensips-http-modules \
    opensips-postgres-module opensips-presence-modules \
    opensips-rabbitmq-modules opensips-tls-module \
    opensips-tls-wolfssl-module opensips-wss-module \
    opensips-xmlrpc-module opensips-json-module \
    opensips-dialplan-module opensips-cachedb-modules 2>/dev/null \
    || apt-get install -y opensips opensips-cli \
      opensips-auth-modules opensips-http-modules \
      opensips-postgres-module opensips-presence-modules \
      opensips-rabbitmq-modules opensips-tls-module \
      opensips-wss-module opensips-xmlrpc-module \
      opensips-cachedb-modules 2>/dev/null \
    || apt-get install -y opensips opensips-cli \
      opensips-auth-modules opensips-http-modules \
      opensips-postgres-module opensips-presence-modules \
      opensips-rabbitmq-modules opensips-tls-module \
      opensips-wss-module opensips-xmlrpc-module
  ensure_opensips_cli
  # enable+start — только после транков и внутренних номеров (start_install_stack / FORCE_RESTART).
  systemctl disable --now opensips >/dev/null 2>&1 || true
  ensure_stopped opensips
  ok "OpenSIPS установлен"
}

deploy_opensips_conf() {
  [[ "${SKIP_OPENSIPS:-0}" == "1" ]] && return
  local src="${INSTALL_DIR}/opensips/opensips.cfg"
  [[ -f "$src" ]] || { warn "нет $src"; return; }

  mkdir -p /etc/opensips
  if [[ -f /etc/opensips/opensips.cfg ]] && [[ "$FORCE_CONFIG" != "1" ]]; then
    if [[ -f /etc/opensips/.mfdc-installed ]]; then
      ok "opensips.cfg уже развёрнут (FORCE_CONFIG=1 чтобы перезаписать)"
      ensure_opensips_logging
      return
    fi
    warn "есть /etc/opensips/opensips.cfg — бэкап и замена на MFDC"
  fi

  do_it "opensips.cfg → /etc/opensips"
  if [[ -f /etc/opensips/opensips.cfg ]] && [[ ! -f /etc/opensips/opensips.cfg.mfdc-bak ]]; then
    cp -a /etc/opensips/opensips.cfg /etc/opensips/opensips.cfg.mfdc-bak
  fi
  install_lf "$src" /etc/opensips/opensips.cfg 0644
  sed -i -E \
    "s|postgres://[^:]+:[^@]+@[^/]+/mfdc|postgres://${MFDC_PG_USER}:${MFDC_PG_PASS}@${MFDC_PG_HOST}:5432/${MFDC_PG_DB}|g" \
    /etc/opensips/opensips.cfg
  touch /etc/opensips/.mfdc-installed
  if opensips -c -f /etc/opensips/opensips.cfg >/tmp/opensips-c.out 2>&1; then
    ok "opensips.cfg: syntax OK"
  else
    warn "opensips -c failed — проверьте модули/пути:"
    sed -n '1,40p' /tmp/opensips-c.out 2>/dev/null || true
  fi
  # Рестарт с MFDC cfg — только после schema bootstrap (см. restart_opensips_after_db).
  ok "opensips.cfg развёрнут (рестарт после mfdc-runner / bootstrap БД)"
  ensure_opensips_logging
}

# OpenSIPS пишет в syslog local0 — направляем в /var/log/opensips.log + logrotate.
ensure_opensips_logging() {
  [[ "${SKIP_OPENSIPS:-0}" == "1" ]] && return

  do_it "OpenSIPS log → /var/log/opensips.log (rsyslog local0)"
  apt-get install -y -qq rsyslog >/dev/null 2>&1 || true
  if ! command -v rsyslogd >/dev/null 2>&1 && ! pkg_installed rsyslog; then
    warn "rsyslog не установлен — смотрите journalctl -u opensips"
    return
  fi

  local src="${INSTALL_DIR}/rsyslog/30-opensips.conf"
  if [[ -f "$src" ]]; then
    install_lf "$src" /etc/rsyslog.d/30-opensips.conf 0644
  else
    cat > /etc/rsyslog.d/30-opensips.conf <<'EOF'
local0.*                         -/var/log/opensips.log
& stop
EOF
    chmod 0644 /etc/rsyslog.d/30-opensips.conf
  fi

  touch /var/log/opensips.log
  chown root:adm /var/log/opensips.log 2>/dev/null || true
  chmod 0640 /var/log/opensips.log

  if [[ -f "${INSTALL_DIR}/logrotate/opensips" ]]; then
    install_lf "${INSTALL_DIR}/logrotate/opensips" /etc/logrotate.d/opensips 0644
  fi

  systemctl enable rsyslog >/dev/null 2>&1 || true
  systemctl restart rsyslog 2>/dev/null || systemctl reload rsyslog 2>/dev/null || true
  ok "логи OpenSIPS: /var/log/opensips.log  (и journalctl -u opensips)"
}

# systemd StandardOutput=append → /var/log/mfdc/*.log (api/broker/runner/caller/sniffer).
# Только *.log: шаблон * подхватил бы уже ротированные api.log-YYYYMMDD(.gz).
ensure_mfdc_logging() {
  mkdir -p /var/log/mfdc
  if getent passwd freeswitch >/dev/null; then
    chown freeswitch:freeswitch /var/log/mfdc 2>/dev/null || true
  fi
  chmod 0755 /var/log/mfdc 2>/dev/null || true

  do_it "logrotate → /etc/logrotate.d/mfdc (daily, rotate 10)"
  command -v logrotate >/dev/null 2>&1 || apt-get install -y -qq logrotate || true

  local src="${INSTALL_DIR}/logrotate/mfdc"
  if [[ -f "$src" ]]; then
    install_lf "$src" /etc/logrotate.d/mfdc 0644
  else
    cat > /etc/logrotate.d/mfdc <<'EOF'
/var/log/mfdc/*.log {
	daily
	rotate 10
	missingok
	notifempty
	compress
	delaycompress
	copytruncate
	dateext
	dateformat -%Y%m%d
	su freeswitch freeswitch
}
EOF
    chmod 0644 /etc/logrotate.d/mfdc
  fi

  if command -v logrotate >/dev/null 2>&1 && logrotate -d /etc/logrotate.d/mfdc >/tmp/mfdc-logrotate-d.out 2>&1; then
    ok "логи MFDC: /var/log/mfdc/*.log (logrotate daily × 10)"
  else
    warn "logrotate -d не прошёл — смотрите /tmp/mfdc-logrotate-d.out"
    sed -n '1,20p' /tmp/mfdc-logrotate-d.out 2>/dev/null || true
  fi
}

# FreeSWITCH mod_logfile → /var/log/freeswitch/core.log.
# Только *.log: шаблон * подхватил бы уже ротированные core.log-YYYYMMDD(.gz)
# и numbered leftovers от maximum-rotate (core.log.1). Перезаписывает пакетный
# /etc/logrotate.d/freeswitch, если он был.
ensure_freeswitch_logging() {
  [[ "${SKIP_FREESWITCH:-0}" == "1" ]] && return

  mkdir -p /var/log/freeswitch
  if getent passwd freeswitch >/dev/null; then
    chown freeswitch:freeswitch /var/log/freeswitch 2>/dev/null || true
  fi
  chmod 0755 /var/log/freeswitch 2>/dev/null || true

  do_it "logrotate → /etc/logrotate.d/freeswitch (daily, rotate 10)"
  command -v logrotate >/dev/null 2>&1 || apt-get install -y -qq logrotate || true

  local src="${INSTALL_DIR}/logrotate/freeswitch"
  if [[ -f "$src" ]]; then
    install_lf "$src" /etc/logrotate.d/freeswitch 0644
  else
    cat > /etc/logrotate.d/freeswitch <<'EOF'
/var/log/freeswitch/*.log {
	daily
	rotate 10
	missingok
	notifempty
	compress
	delaycompress
	copytruncate
	dateext
	dateformat -%Y%m%d
	su freeswitch freeswitch
}
EOF
    chmod 0644 /etc/logrotate.d/freeswitch
  fi

  if command -v logrotate >/dev/null 2>&1 && logrotate -d /etc/logrotate.d/freeswitch >/tmp/freeswitch-logrotate-d.out 2>&1; then
    ok "логи FreeSWITCH: /var/log/freeswitch/*.log (logrotate daily × 10)"
  else
    warn "logrotate -d не прошёл — смотрите /tmp/freeswitch-logrotate-d.out"
    sed -n '1,20p' /tmp/freeswitch-logrotate-d.out 2>/dev/null || true
  fi
}

# Ждём таблицы OpenSIPS (создаёт mfdc-runner bootstrap) и поднимаем opensips.
# При обычной установке не вызывается: SIP-край без транков и номеров не стартуем.
restart_opensips_after_db() {
  [[ "${SKIP_OPENSIPS:-0}" == "1" ]] && return
  [[ -f /etc/opensips/.mfdc-installed ]] || return

  if (( MFDC_DEFER_START )); then
    skip "OpenSIPS не запускаем — после транков и внутренних номеров: systemctl enable --now opensips"
    systemctl disable --now opensips >/dev/null 2>&1 || true
    ensure_stopped opensips
    return
  fi

  do_it "ожидание schema OpenSIPS (public.location)…"
  local i ok_db=0
  export PGPASSWORD="${MFDC_PG_PASS}"
  for i in $(seq 1 90); do
    if psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
      "SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='location'" 2>/dev/null \
      | grep -qx 1; then
      ok_db=1
      break
    fi
    sleep 1
  done
  unset PGPASSWORD
  if ((ok_db)); then
    ok "public.location есть — restart opensips"
  else
    warn "public.location ещё нет (90с) — всё равно пробуем restart opensips"
  fi
  systemctl enable opensips >/dev/null 2>&1 || true
  systemctl restart opensips || {
    warn "restart opensips failed — journalctl -xeu opensips.service"
    journalctl -u opensips -n 30 --no-pager 2>/dev/null || true
  }
  if svc_active opensips; then
    ok "opensips active"
  else
    warn "opensips НЕ active"
  fi
}

# --- RabbitMQ ----------------------------------------------------------------
ensure_rabbitmq_user() {
  if ! command -v rabbitmqctl >/dev/null 2>&1; then
    warn "rabbitmqctl не найден"
    return 0
  fi
  if (( MFDC_DEFER_START )); then
    skip "RabbitMQ user ${MFDC_RABBIT_USER} — создастся при первом старте брокера"
    return 0
  fi
  systemctl start rabbitmq-server 2>/dev/null || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    rabbitmqctl status >/dev/null 2>&1 && break
    sleep 1
  done
  if ! rabbitmqctl status >/dev/null 2>&1; then
    warn "RabbitMQ не отвечает — user ${MFDC_RABBIT_USER} не создан"
    return 0
  fi

  if rabbitmqctl list_users 2>/dev/null | awk '{print $1}' | grep -qx "${MFDC_RABBIT_USER}"; then
    ok "RabbitMQ user ${MFDC_RABBIT_USER} уже есть — обновим пароль/права"
    rabbitmqctl change_password "${MFDC_RABBIT_USER}" "${MFDC_RABBIT_PASS}" >/dev/null || true
  else
    do_it "RabbitMQ user ${MFDC_RABBIT_USER}"
    rabbitmqctl add_user "${MFDC_RABBIT_USER}" "${MFDC_RABBIT_PASS}" || true
  fi
  rabbitmqctl set_user_tags "${MFDC_RABBIT_USER}" administrator >/dev/null || true
  rabbitmqctl set_permissions -p / "${MFDC_RABBIT_USER}" ".*" ".*" ".*" >/dev/null || true
  if rabbitmqctl list_users 2>/dev/null | awk '{print $1}' | grep -qx guest; then
    do_it "удаление guest"
    rabbitmqctl delete_user guest >/dev/null 2>&1 || true
  else
    ok "user guest уже удалён"
  fi
}

deploy_rabbitmq_conf() {
  mkdir -p /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq
  install_lf "${INSTALL_DIR}/rabbitmq/enabled_plugins" /etc/rabbitmq/enabled_plugins 0644
  install_lf "${INSTALL_DIR}/rabbitmq/rabbitmq.conf" /etc/rabbitmq/rabbitmq.conf 0644
  if [[ -f "${INSTALL_DIR}/rabbitmq/rabbitmq-env.conf" ]]; then
    install_lf "${INSTALL_DIR}/rabbitmq/rabbitmq-env.conf" /etc/rabbitmq/rabbitmq-env.conf 0644
  else
    cat > /etc/rabbitmq/rabbitmq-env.conf <<'EOF'
NODENAME=rabbit@localhost
NODE_IP_ADDRESS=127.0.0.1
EOF
    chmod 0644 /etc/rabbitmq/rabbitmq-env.conf
  fi
  if getent passwd rabbitmq >/dev/null; then
    chown -R rabbitmq:rabbitmq /etc/rabbitmq /var/lib/rabbitmq /var/log/rabbitmq 2>/dev/null || true
  fi
}

start_rabbitmq_or_die() {
  systemctl enable rabbitmq-server >/dev/null 2>&1 || true
  if systemctl start rabbitmq-server; then
    local i
    for i in $(seq 1 20); do
      if rabbitmqctl status >/dev/null 2>&1; then
        ok "rabbitmq-server active"
        return 0
      fi
      sleep 1
    done
  fi
  warn "rabbitmq-server не стартовал — последние логи:"
  journalctl -u rabbitmq-server -n 80 --no-pager 2>/dev/null || true
  tail -n 40 /var/log/rabbitmq/*.log 2>/dev/null || true
  die "RabbitMQ не запустился. На сервере: journalctl -xeu rabbitmq-server.service"
}

# Порог свободного места, ниже которого RabbitMQ поднимает resource alarm и замораживает publisher'ов.
# Для платформы это не абстракция: mfdc-broker видит блокировку как «шина событий лежит» и отказывает
# НОВЫМ звонкам с SIP 503, чтобы они не прошли мимо CDR. Прежние 5GB на диске 45-50GB срабатывали
# задолго до реальной нехватки места.
#
# На уже развёрнутых системах /etc/rabbitmq/rabbitmq.conf сознательно не перезаписывается целиком
# (там могут быть правки администратора), поэтому значение доводится точечно — и ТОЛЬКО когда оно
# всё ещё равно нашему прежнему дефолту. Свой порог, выставленный администратором, не трогаем: тот же
# принцип, что у смены заводского ESL-пароля.
ensure_rabbitmq_disk_limit() {
  local conf=/etc/rabbitmq/rabbitmq.conf cur=""
  [[ -f "$conf" ]] || return 0

  cur="$(sed -nE 's/^[[:space:]]*disk_free_limit\.absolute[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$conf" | tail -1 || true)"
  if [[ -z "$cur" ]]; then
    warn "RabbitMQ: disk_free_limit.absolute не задан в ${conf} — оставляю как есть"
    return 0
  fi
  if [[ "$cur" == "2GB" ]]; then
    ok "RabbitMQ: порог свободного места уже 2GB"
    return 0
  fi
  if [[ "$cur" != "5GB" ]]; then
    ok "RabbitMQ: порог свободного места ${cur} задан администратором — не трогаем"
    return 0
  fi

  do_it "RabbitMQ: порог свободного места 5GB → 2GB (прежний дефолт срабатывал раньше реальной нехватки)"
  cp -p "$conf" "${conf}.mfdc-bak" 2>/dev/null || true
  if ! sed -i -E 's/^([[:space:]]*disk_free_limit\.absolute[[:space:]]*=[[:space:]]*).*/\12GB/' "$conf"; then
    warn "RabbitMQ: не удалось изменить ${conf} — порог остался ${cur}"
    return 0
  fi
  # Конфиг читается только при старте; если узел жив — применяем сразу, чтобы снять уже висящий alarm
  # и не ждать рестарта (он бы оборвал текущие соединения).
  if svc_active rabbitmq-server; then
    rabbitmqctl set_disk_free_limit 2GB >/dev/null 2>&1 \
      || warn "RabbitMQ: значение в конфиге изменено, но применить на живом узле не удалось — вступит в силу при рестарте"
  fi
}

install_rabbitmq() {
  [[ "${SKIP_RABBITMQ:-0}" == "1" ]] && { skip "RabbitMQ"; return; }
  ensure_hostname_loopback

  if pkg_installed rabbitmq-server; then
    ok "RabbitMQ уже установлен"
    if [[ "$FORCE_CONFIG" == "1" ]] || [[ ! -f /etc/rabbitmq/rabbitmq.conf ]]; then
      deploy_rabbitmq_conf
    else
      mkdir -p /etc/rabbitmq
      if [[ -f "${INSTALL_DIR}/rabbitmq/rabbitmq-env.conf" ]]; then
        install_lf "${INSTALL_DIR}/rabbitmq/rabbitmq-env.conf" /etc/rabbitmq/rabbitmq-env.conf 0644
      fi
      ok "конфиг RabbitMQ сохранён (/etc/rabbitmq/rabbitmq.conf не трогаем); env NODENAME обновлён"
    fi
    ensure_rabbitmq_disk_limit
    systemctl enable rabbitmq-server >/dev/null 2>&1 || true
    ensure_stopped rabbitmq-server
    ensure_rabbitmq_user
    return
  fi

  do_it "RabbitMQ (Team RabbitMQ apt)"
  if [[ ! -f /usr/share/keyrings/com.rabbitmq.team.gpg ]]; then
    curl -1sLf "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" \
      | gpg --dearmor \
      | tee /usr/share/keyrings/com.rabbitmq.team.gpg > /dev/null
  fi
  if [[ ! -f /etc/apt/sources.list.d/rabbitmq.list ]]; then
    tee /etc/apt/sources.list.d/rabbitmq.list >/dev/null <<EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-server/debian/bookworm bookworm main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-server/debian/bookworm bookworm main
EOF
  fi

  apt-get update -y
  apt-get install -y erlang-base \
    erlang-asn1 erlang-crypto erlang-eldap erlang-ftp erlang-inets \
    erlang-mnesia erlang-os-mon erlang-parsetools erlang-public-key \
    erlang-runtime-tools erlang-snmp erlang-ssl \
    erlang-syntax-tools erlang-tftp erlang-tools erlang-xmerl

  # Конфиг ДО пакета: postinst rabbitmq-server сразу делает systemctl start.
  # listeners.tcp=127.0.0.1 не задаёт имя узла — без env будет rabbit@2gis и epmd timeout.
  do_it "конфиг RabbitMQ до apt (NODENAME=rabbit@localhost)"
  deploy_rabbitmq_conf

  apt-get install -y rabbitmq-server --fix-missing
  deploy_rabbitmq_conf
  systemctl enable rabbitmq-server >/dev/null 2>&1 || true
  ensure_stopped rabbitmq-server
  ensure_rabbitmq_user
  ok "RabbitMQ установлен"
}

# --- RTPEngine ---------------------------------------------------------------
detect_public_ip() {
  if [[ -n "${MFDC_PUBLIC_IP:-}" ]]; then
    echo "${MFDC_PUBLIC_IP}" | tr -d '[:space:]'
    return
  fi
  local ip=""
  # default route src
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  # не RFC1918 / не link-local
  if [[ "$ip" =~ ^10\. ]] || [[ "$ip" =~ ^192\.168\. ]] || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] \
     || [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]] \
     || [[ "$ip" == "127."* ]] || [[ -z "$ip" ]]; then
    ip="$(curl -4 -fsS --max-time 3 https://ifconfig.me/ip 2>/dev/null || true)"
    ip="$(echo "$ip" | tr -d '[:space:]')"
  fi
  if [[ -z "$ip" ]] && [[ -t 0 ]]; then
    read -r -p "Публичный IPv4 сервера (для rtpengine ex/): " ip || true
    ip="$(echo "${ip:-}" | tr -d '[:space:]')"
  fi
  [[ -n "$ip" ]] || die "не удалось определить публичный IP — задайте MFDC_PUBLIC_IP=x.x.x.x"
  echo "$ip"
}

deploy_rtpengine_conf() {
  [[ "${SKIP_RTPENGINE:-0}" == "1" ]] && return
  local conf="/etc/rtpengine/rtpengine.conf"
  local src="${INSTALL_DIR}/rtpengine/rtpengine.conf"
  local pub marker table_id

  mkdir -p /etc/rtpengine
  pub="$(detect_public_ip)"
  MFDC_PUBLIC_IP="$pub"
  marker="ex/${pub}"

  # table=0 — kernel forwarding (нужен nft_rtpengine/xt_RTPENGINE);
  # table=-1 — только userspace (без ERR про KERNEL TABLE).
  if rtpengine_kernel_ready; then
    table_id=0
  else
    table_id=-1
  fi

  if [[ -f "$conf" ]] && [[ "$FORCE_CONFIG" != "1" ]] \
    && grep -qF "interface = ${marker}" "$conf" 2>/dev/null \
    && grep -qE "^[[:space:]]*table[[:space:]]*=[[:space:]]*${table_id}([[:space:]]|#|$)" "$conf" 2>/dev/null; then
    ok "rtpengine.conf уже с interface=${marker} table=${table_id}"
    return
  fi

  do_it "rtpengine.conf → interface=ex/${pub};in/127.0.0.1 table=${table_id}"
  if [[ -f "$conf" ]] && [[ ! -f /etc/rtpengine/rtpengine.conf.mfdc-bak ]]; then
    cp -a "$conf" /etc/rtpengine/rtpengine.conf.mfdc-bak
  fi
  if [[ -f "$src" ]]; then
    tr -d '\r' < "$src" | sed -e "s|__PUBLIC_IP__|${pub}|g" -e "s|^table = .*|table = ${table_id}|" > "$conf"
  else
    cat > "$conf" <<EOF
[rtpengine]

table = ${table_id}
interface = ex/${pub};in/127.0.0.1
listen-ng = 127.0.0.1:60000

port-min = 10000
port-max = 19999

timeout = 60
silent-timeout = 3600
tos = 184
EOF
  fi
  chmod 0644 "$conf"
  if [[ "$table_id" == "-1" ]]; then
    ok "rtpengine: public IP=${pub} table=-1 (userspace)"
  else
    ok "rtpengine: public IP=${pub} table=0 (kernel)"
  fi
}

# 0 = kernel module загружен и готов к table=0
rtpengine_kernel_ready() {
  lsmod 2>/dev/null | grep -qE '^(nft_rtpengine|xt_RTPENGINE)\b' && return 0
  [[ -e /proc/rtpengine/control ]] && return 0
  return 1
}

ensure_rtpengine_kernel() {
  # DKMS-модуль + headers — иначе table=0 даёт ERR KERNEL FORWARDING DISABLED
  do_it "rtpengine kernel module (headers + dkms)"
  apt-get update -qq 2>/dev/null || true

  local headers_exact="linux-headers-$(uname -r)"
  if apt-cache show "$headers_exact" >/dev/null 2>&1; then
    apt-get install -y -qq "$headers_exact" \
      || warn "не удалось поставить ${headers_exact}"
  else
    warn "пакета ${headers_exact} нет в apt (ядро новее зеркала?) — пробуем linux-headers-amd64"
    apt-get install -y -qq linux-headers-amd64 2>/dev/null \
      || warn "linux-headers-amd64 тоже не встал — kernel forwarding, скорее всего, недоступен без reboot на ядро с headers"
  fi

  # Sipwise mr13: имена пакетов плавают между релизами
  apt-get install -y -qq ngcp-rtpengine-kernel-dkms 2>/dev/null \
    || apt-get install -y -qq rtpengine-kernel-dkms 2>/dev/null \
    || warn "ngcp-rtpengine-kernel-dkms не установился"
  apt-get install -y -qq ngcp-rtpengine-iptables 2>/dev/null \
    || apt-get install -y -qq ngcp-rtpengine-utils 2>/dev/null \
    || true

  # DKMS мог собрать модуль только что — подхватить
  if command -v dkms >/dev/null 2>&1; then
    dkms autoinstall 2>/dev/null || true
  fi

  # загрузить модуль (новый nft_* или legacy xt_*)
  depmod -a 2>/dev/null || true
  modprobe nft_rtpengine 2>/dev/null \
    || modprobe xt_RTPENGINE 2>/dev/null \
    || true

  if rtpengine_kernel_ready; then
    ok "rtpengine kernel module загружен"
  else
    warn "rtpengine kernel module недоступен — будет table=-1 (userspace). Часто помогает: apt update && reboot, затем install снова; либо отключить Secure Boot"
  fi
}

restart_rtpengine() {
  [[ "${SKIP_RTPENGINE:-0}" == "1" ]] && return
  if (( MFDC_DEFER_START )); then
    ensure_stopped ngcp-rtpengine-daemon
    ensure_stopped rtpengine
    return
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q '^ngcp-rtpengine-daemon'; then
    systemctl restart ngcp-rtpengine-daemon || warn "restart ngcp-rtpengine-daemon failed"
  elif systemctl list-unit-files 2>/dev/null | grep -q '^rtpengine'; then
    systemctl restart rtpengine || warn "restart rtpengine failed"
  fi
  # OpenSIPS НЕ рестартуем здесь: при первом install MFDC cfg уже на диске,
  # а schema ещё нет → ранний restart ломает opensips. Рестарт — в restart_opensips_after_db.
}

install_rtpengine() {
  [[ "${SKIP_RTPENGINE:-0}" == "1" ]] && { skip "rtpengine"; return; }

  if ! any_pkg_installed ngcp-rtpengine ngcp-rtpengine-daemon rtpengine; then
    do_it "ngcp-rtpengine"
    if [[ ! -f /etc/apt/sources.list.d/rtpengine.list ]]; then
      wget -q https://deb.sipwise.com/spce/ngcp-keyring-latest.deb -O /tmp/ngcp-keyring-latest.deb
      dpkg -i /tmp/ngcp-keyring-latest.deb || true
      rm -f /tmp/ngcp-keyring-latest.deb
      echo "deb https://deb.sipwise.com/spce/mr13.3.1 bookworm main" \
        > /etc/apt/sources.list.d/rtpengine.list
    fi
    apt-get update -qq
    apt-get install -y ngcp-rtpengine 2>/dev/null || apt-get install -y ngcp-rtpengine-daemon
  else
    ok "rtpengine уже установлен"
  fi

  systemctl enable ngcp-rtpengine-daemon >/dev/null 2>&1 \
    || systemctl enable rtpengine >/dev/null 2>&1 || true

  ensure_rtpengine_kernel
  deploy_rtpengine_conf
  restart_rtpengine
  ok "rtpengine установлен"
}

# --- MFDC apps ---------------------------------------------------------------
ensure_rabbitmq_url_in_settings() {
  local conf="${OPT_MFDC}/settings.conf"
  local url="amqp://${MFDC_RABBIT_USER}:${MFDC_RABBIT_PASS}@127.0.0.1:5672/"
  [[ -f "$conf" ]] || return 0
  if grep -qE '^\[rabbitmq\]' "$conf" && grep -qE '^[[:space:]]*url[[:space:]]*=' "$conf"; then
    ok "settings.conf: [rabbitmq] url уже задан"
    return 0
  fi
  if grep -qE '^\[rabbitmq\]' "$conf"; then
    sed -i "/^\[rabbitmq\]/a url = ${url}" "$conf"
  else
    cat >> "$conf" <<EOF

[rabbitmq]
url = ${url}
EOF
  fi
  ok "settings.conf: rabbitmq.url=${url}"
}

# JWT для mfdc-api: если в [auth] jwt_secret пуст/отсутствует — openssl rand -hex 32.
ensure_jwt_secret_in_settings() {
  local conf="${OPT_MFDC}/settings.conf"
  [[ -f "$conf" ]] || return 0
  if grep -qE '^[[:space:]]*jwt_secret[[:space:]]*=[[:space:]]*[^[:space:]]+' "$conf"; then
    ok "settings.conf: [auth] jwt_secret уже задан"
    return 0
  fi
  local secret
  secret="$(openssl rand -hex 32)"
  if grep -qE '^[[:space:]]*jwt_secret[[:space:]]*=' "$conf"; then
    sed -i -E "s|^[[:space:]]*jwt_secret[[:space:]]*=.*|jwt_secret = ${secret}|" "$conf"
  elif grep -qE '^\[auth\]' "$conf"; then
    sed -i "/^\[auth\]/a jwt_secret = ${secret}" "$conf"
  else
    cat >> "$conf" <<EOF

[auth]
jwt_secret = ${secret}
EOF
  fi
  ok "settings.conf: [auth] jwt_secret сгенерирован (openssl rand -hex 32)"
}

# Копирует бинарник; выставляет MFDC_APP_UPDATE=1 если файл новый или изменился.
deploy_bin() {
  local name="$1" src="$2" dst="$3"
  if [[ ! -f "$src" ]]; then
    warn "нет бинарника $src"
    return
  fi
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    ok "$name уже актуален"
    return
  fi
  if [[ -f "$dst" ]]; then
    do_it "обновление $name → $dst"
  else
    do_it "установка $name → $dst"
  fi
  install -m 0755 "$src" "$dst"
  chown freeswitch:freeswitch "$dst" 2>/dev/null || true
  MFDC_APP_UPDATE=1
  MFDC_UPDATED_BINS="${MFDC_UPDATED_BINS} ${name}"
}

# Заменялся ли бинарник в этом запуске.
mfdc_bin_updated() {
  case " ${MFDC_UPDATED_BINS} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Публичный ключ проверки лицензий кладётся в БД (system.platform_settings.licence_public_key), а не файлом.
# Файл на диске приходилось руками разносить по узлам, он молча пропадал при передеплое, и по нему нельзя было
# понять из платформы, стоит ли ключ вообще. Ключ публичный — секретности БД тут ничего не отнимает.
# Хранится base64 сырых 32 байт; из пакета берётся тот же install/public.key, что и раньше.
# Публичный SIP-адрес платформы: уходит в Contact при регистрации транка (у Asterisk это адрес в
# Contact: <sip:DID@IP:5060>). Провайдер по нему шлёт нам входящие; без него в Contact оставался бы хост
# самого провайдера, и часть операторов отвечает на такой REGISTER 403 / invalid contact.
# Только если ещё не задан — значение админа из UI не перетираем.
install_sip_public_addr() {
  command -v psql >/dev/null 2>&1 || return
  ensure_postgres_running || { warn "postgresql не running — публичный SIP-адрес не записан"; return; }
  local pub port
  pub="$(detect_public_ip 2>/dev/null || true)"
  [[ -n "$pub" ]] || return

  # Первый UDP-сокет БЕЗ tag internal: 6062 помечен internal и держит связку с FreeSWITCH, регистрация
  # транка должна уходить с того же порта, на который приходят звонки снаружи.
  port="$(awk '/^[[:space:]]*socket[[:space:]]*=[[:space:]]*udp:/ && !/tag[[:space:]]+internal/ {
                 sub(/.*udp:[^:]*:/, ""); sub(/[^0-9].*/, ""); if ($0 != "") { print; exit } }' \
            /etc/opensips/opensips.cfg 2>/dev/null || true)"
  [[ -n "$port" ]] || port=6060

  if sudo -u postgres psql -v ON_ERROR_STOP=1 -q -d "${MFDC_PG_DB}" >/dev/null <<SQL
CREATE SCHEMA IF NOT EXISTS system;
CREATE TABLE IF NOT EXISTS system.platform_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by bigint
);
ALTER TABLE system.platform_settings ADD COLUMN IF NOT EXISTS sip_public_addr text;
INSERT INTO system.platform_settings (id, settings, sip_public_addr)
VALUES (1, '{}'::jsonb, '${pub}:${port}')
ON CONFLICT (id) DO UPDATE SET sip_public_addr = COALESCE(NULLIF(system.platform_settings.sip_public_addr, ''), EXCLUDED.sip_public_addr);
SQL
  then
    ok "публичный SIP-адрес для Contact: ${pub}:${port}"
  else
    warn "не удалось записать публичный SIP-адрес — задайте его в «Настройки → API», иначе регистрируемые транки уйдут с Contact на хосте провайдера"
  fi
}

install_licence_public_key() {
  local pub_src=""
  if [[ -f "${INSTALL_DIR}/public.key" ]]; then
    pub_src="${INSTALL_DIR}/public.key"
  elif [[ -f "${INSTALL_DIR}/licence/public.key" ]]; then
    pub_src="${INSTALL_DIR}/licence/public.key"
  fi
  if [[ -z "$pub_src" ]]; then
    warn "нет install/public.key — лицензии не проверятся (демо-режим), пока ключ не попадёт в system.platform_settings"
    return
  fi

  local size
  size="$(wc -c < "$pub_src" | tr -d '[:space:]')"
  if [[ "$size" != "32" ]]; then
    warn "install/public.key размером ${size} B вместо 32 — это не сырой Ed25519 ключ, пропускаем"
    return
  fi

  local pub_b64
  pub_b64="$(base64 -w0 < "$pub_src")"

  if ! command -v psql >/dev/null 2>&1; then
    warn "psql не найден — ключ лицензий не записан в БД"
    return
  fi
  ensure_postgres_running || { warn "postgresql не running — ключ лицензий не записан"; return; }

  # Таблицу обычно создаёт mfdc-runner, но установщик может отработать раньше первого старта сервисов,
  # поэтому схема/таблица/колонка создаются здесь же — все операции идемпотентные.
  if sudo -u postgres psql -v ON_ERROR_STOP=1 -q -d "${MFDC_PG_DB}" >/dev/null <<SQL
CREATE SCHEMA IF NOT EXISTS system;
CREATE TABLE IF NOT EXISTS system.platform_settings (
  id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by bigint
);
ALTER TABLE system.platform_settings ADD COLUMN IF NOT EXISTS licence_public_key text;
INSERT INTO system.platform_settings (id, settings, licence_public_key)
VALUES (1, '{}'::jsonb, '${pub_b64}')
ON CONFLICT (id) DO UPDATE SET licence_public_key = EXCLUDED.licence_public_key;
SQL
  then
    do_it "public.key → system.platform_settings.licence_public_key"
  else
    warn "не удалось записать ключ лицензий в БД — лицензии останутся непроверяемыми"
    return
  fi

  # Старые копии ключа больше не читаются ни одним сервисом: убираем, чтобы не создавать иллюзию, что
  # лицензирование настроено файлом.
  local legacy
  for legacy in "${OPT_MFDC}/licence/public.key" "${OPT_MFDC}/public.key"; do
    if [[ -f "$legacy" ]]; then
      do_it "удаление устаревшего ${legacy} (ключ теперь в БД)"
      rm -f "$legacy"
    fi
  done
  rmdir "${OPT_MFDC}/licence" 2>/dev/null || true
}

# Адрес HTTP mfdc-runner из /opt/mfdc/settings.conf ([mfdc-runner] bind). Пусто = медиа-HTTP выключен.
mfdc_runner_bind() {
  local f="${OPT_MFDC}/settings.conf"
  [[ -f "$f" ]] || return 0
  awk '
    /^[[:space:]]*\[.*\][[:space:]]*$/ {
      sec=$0; sub(/^[[:space:]]*\[/,"",sec); sub(/\][[:space:]]*$/,"",sec); next
    }
    sec=="mfdc-runner" && /^[[:space:]]*bind[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/,""); sub(/[[:space:]]*$/,""); print; exit
    }
  ' "$f"
}

# Ждём, пока новый mfdc-runner раскатает структуру БД.
#
# Это не косметика. Миграционных файлов у платформы нет: всю структуру раскатывает runner на старте
# (EnsureSchemaDeltas), и только ПОСЛЕ этого поднимает свой HTTP — поэтому «порт отвечает» и есть точный
# признак «дельты применены». Обновление, где добавилась колонка, с фиксированным sleep — гонка: mfdc-api и
# mfdc-broker успевают подняться на старой схеме. Они обязаны деградировать, а не падать, но деградация
# выглядит как «настройка не сохраняется» до следующего рестарта.
#
# Любой отказ здесь — предупреждение, а не die: сервисы всё равно надо поднять, а незакрытая гонка хуже
# видна, чем прерванное обновление.
wait_for_mfdc_runner_schema() {
  local bind port host i=0 max="${MFDC_RUNNER_WAIT_SEC:-90}"
  bind="$(mfdc_runner_bind)"
  port="${bind##*:}"
  if [[ -z "$bind" || "$bind" == "$port" ]] || ! [[ "$port" =~ ^[0-9]+$ ]]; then
    # bind не задан (медиа-HTTP выключен) или не разобрался — порта, по которому видно готовность, нет.
    warn "порт mfdc-runner не определён по ${OPT_MFDC}/settings.conf — ждём 5с вслепую"
    sleep 5
    return 0
  fi
  host="${bind%:*}"
  case "$host" in ""|"0.0.0.0"|"[::]"|"*") host="127.0.0.1" ;; esac
  while (( i < max )); do
    if timeout 1 bash -c ">/dev/tcp/${host}/${port}" 2>/dev/null; then
      ok "mfdc-runner раскатал структуру БД (${i}с)"
      return 0
    fi
    if ! svc_active mfdc-runner; then
      warn "mfdc-runner не active — journalctl -u mfdc-runner; продолжаем без ожидания"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  warn "mfdc-runner не открыл ${host}:${port} за ${max}с — mfdc-api/mfdc-broker стартуют, структура БД могла не примениться"
}

restart_mfdc_services() {
  local reason="${1:-обновление MFDC}"
  do_it "${reason}: restart mfdc-runner / mfdc-api / mfdc-broker"
  # runner первым всегда: он владеет структурой БД. Но ЖДЁМ его только когда бинарник новый — тогда в нём
  # могут быть новые дельты, и остальные сервисы не должны подниматься на старой схеме.
  systemctl restart mfdc-runner || die "mfdc-runner не стартовал — смотрите journalctl -u mfdc-runner"
  if mfdc_bin_updated mfdc-runner; then
    do_it "новый mfdc-runner: ждём применения структуры БД перед стартом остальных"
    wait_for_mfdc_runner_schema
  else
    sleep 3
  fi
  systemctl restart mfdc-api || warn "mfdc-api не стартовал"
  systemctl restart mfdc-broker || warn "mfdc-broker не стартовал"
  if [[ -f "${OPT_MFDC}/mfdc-caller" ]]; then
    systemctl enable mfdc-caller >/dev/null 2>&1 || true
    systemctl restart mfdc-caller || warn "mfdc-caller не стартовал"
  fi
  if [[ -f "${OPT_MFDC}/mfdc-sniffer" ]]; then
    systemctl enable mfdc-sniffer >/dev/null 2>&1 || true
    systemctl restart mfdc-sniffer || warn "mfdc-sniffer не стартовал"
  fi
}

mfdc_bin_names() { echo mfdc-api mfdc-broker mfdc-runner mfdc-caller mfdc-sniffer; }

# После бэкапа: не больше MFDC_BACKUP_KEEP stamp-каталогов (11-й — самый старый удаляем).
prune_mfdc_backups() {
  local keep="${MFDC_BACKUP_KEEP:-10}" root="${MFDC_BACKUP_ROOT}"
  [[ -d "$root" ]] || return 0
  local dirs=() d i=0
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r)
  for d in "${dirs[@]+"${dirs[@]}"}"; do
    i=$((i + 1))
    if (( i > keep )); then
      do_it "удаление старого бэкапа ${root}/${d}"
      rm -rf "${root}/${d}"
    fi
  done
}

# Бэкап текущих bin/UI, которые будут заменены. Путь в MFDC_LAST_BACKUP_DIR (пусто = нечего).
backup_mfdc_before_update() {
  local bin_dir="$1"
  local name stamp backup_dir need=0 backup_ui=0
  local -a to_backup_bins=()
  MFDC_LAST_BACKUP_DIR=""

  for name in $(mfdc_bin_names); do
    [[ -f "${bin_dir}/${name}" ]] || continue
    [[ -f "${OPT_MFDC}/${name}" ]] || continue
    if ! cmp -s "${bin_dir}/${name}" "${OPT_MFDC}/${name}"; then
      to_backup_bins+=("$name")
      need=1
    fi
  done
  if [[ -d "${INSTALL_DIR}/ui" ]] && [[ -f "${INSTALL_DIR}/ui/index.html" ]] \
    && ui_dist_complete "${INSTALL_DIR}/ui" \
    && [[ -d "${UI_WWW}" ]] && [[ -f "${UI_WWW}/index.html" ]] \
    && ui_tree_differs "${INSTALL_DIR}/ui" "${UI_WWW}"; then
    backup_ui=1
    need=1
  fi
  ((need)) || return 0

  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="${MFDC_BACKUP_ROOT}/${stamp}"
  mkdir -p "$backup_dir"
  {
    echo "stamp=${stamp}"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "host=$(hostname -f 2>/dev/null || hostname)"
  } > "${backup_dir}/MANIFEST.txt"

  for name in "${to_backup_bins[@]+"${to_backup_bins[@]}"}"; do
    do_it "бэкап ${name} → ${backup_dir}/${name}"
    cp -a "${OPT_MFDC}/${name}" "${backup_dir}/${name}"
    echo "bin=${name}" >> "${backup_dir}/MANIFEST.txt"
  done
  if ((backup_ui)); then
    do_it "бэкап UI → ${backup_dir}/ui/"
    mkdir -p "${backup_dir}/ui"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a "${UI_WWW}/" "${backup_dir}/ui/"
    else
      cp -a "${UI_WWW}/." "${backup_dir}/ui/"
    fi
    echo "ui=1" >> "${backup_dir}/MANIFEST.txt"
  fi

  ln -sfn "${stamp}" "${MFDC_BACKUP_ROOT}/previous"
  prune_mfdc_backups
  MFDC_LAST_BACKUP_DIR="$backup_dir"
  ok "бэкап: ${backup_dir} (previous → ${stamp})"
}

resolve_mfdc_backup_dir() {
  local root="${MFDC_BACKUP_ROOT}" prev target
  [[ -d "$root" ]] || die "нет бэкапов: ${root} (сначала bash install.sh -update)"
  if [[ -L "${root}/previous" || -d "${root}/previous" ]]; then
    prev="$(readlink -f "${root}/previous" 2>/dev/null || true)"
    if [[ -n "$prev" && -d "$prev" ]]; then
      printf '%s\n' "$prev"
      return 0
    fi
  fi
  target="$(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r | head -1 || true)"
  [[ -n "$target" ]] || die "нет stamp-бэкапов в ${root}"
  printf '%s\n' "${root}/${target}"
}

# Режим bash install.sh -update: только bin/ (+ ui/). Рестарт mfdc-* — только если сменился бинарник.
# UI — статика nginx, рестарт сервисов не нужен.
update_mfdc_apps() {
  need_root
  require_amd64
  local bin_dir="${INSTALL_DIR}/bin"
  local name
  [[ -d "$bin_dir" ]] || die "нет ${bin_dir} — положите готовые бинарники (pack.sh)"
  [[ -d "${OPT_MFDC}" ]] || die "нет ${OPT_MFDC} — сначала полная установка (bash install.sh)"

  MFDC_APP_UPDATE=0
  MFDC_UI_UPDATE=0
  MFDC_UPDATED_BINS=""
  log "режим -update: bin/ → ${OPT_MFDC} (бэкап → ${MFDC_BACKUP_ROOT})"

  ensure_mfdc_logging
  ensure_freeswitch_logging

  backup_mfdc_before_update "$bin_dir"

  for name in $(mfdc_bin_names); do
    if [[ -f "${bin_dir}/${name}" ]]; then
      deploy_bin "$name" "${bin_dir}/${name}" "${OPT_MFDC}/${name}"
    else
      skip "$name (нет в ${bin_dir})"
    fi
  done

  if [[ -d "${INSTALL_DIR}/ui" ]] && [[ -f "${INSTALL_DIR}/ui/index.html" ]]; then
    if ! ui_dist_complete "${INSTALL_DIR}/ui"; then
      warn "UI в пакете неполный (нет $(grep -oE '/assets/index-[A-Za-z0-9._-]+\.js' "${INSTALL_DIR}/ui/index.html" | head -1 || echo assets/index-*.js)) — ${UI_WWW} не трогаем"
    elif ui_tree_differs "${INSTALL_DIR}/ui" "${UI_WWW}"; then
      do_it "обновление UI → ${UI_WWW}"
      mkdir -p "${UI_WWW}"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${INSTALL_DIR}/ui/" "${UI_WWW}/"
      else
        find "${UI_WWW}" -mindepth 1 -delete 2>/dev/null || true
        cp -a "${INSTALL_DIR}/ui/." "${UI_WWW}/"
      fi
      chown -R www-data:www-data "${UI_WWW}" 2>/dev/null || true
      MFDC_UI_UPDATE=1
    else
      ok "UI уже актуален (${UI_WWW})"
    fi
  else
    skip "UI (нет ${INSTALL_DIR}/ui)"
  fi

  if [[ -n "${MFDC_UPDATED_BINS}" ]]; then
    restart_mfdc_services "update bin"
    if [[ -n "${MFDC_LAST_BACKUP_DIR:-}" ]]; then
      ok "обновление завершено; откат: bash install.sh -update-rollback"
      ok "бэкап: ${MFDC_LAST_BACKUP_DIR}"
    else
      ok "обновление завершено"
    fi
  elif (( MFDC_UI_UPDATE )); then
    ok "UI обновлён (${UI_WWW}) — рестарт mfdc-* не нужен (файлы отдаёт nginx)"
    if [[ -n "${MFDC_LAST_BACKUP_DIR:-}" ]]; then
      ok "откат UI: bash install.sh -update-rollback"
      ok "бэкап: ${MFDC_LAST_BACKUP_DIR}"
    fi
  else
    ok "bin/ и UI без изменений — рестарт не нужен"
  fi
}

# Режим bash install.sh -update-rollback: восстановить из backup/previous.
rollback_mfdc_apps() {
  need_root
  require_amd64
  local backup_dir name restored=0
  [[ -d "${OPT_MFDC}" ]] || die "нет ${OPT_MFDC}"

  backup_dir="$(resolve_mfdc_backup_dir)"
  log "режим -update-rollback: ${backup_dir} → ${OPT_MFDC}"

  for name in $(mfdc_bin_names); do
    if [[ -f "${backup_dir}/${name}" ]]; then
      do_it "restore ${name}"
      install -m 0755 "${backup_dir}/${name}" "${OPT_MFDC}/${name}"
      chown freeswitch:freeswitch "${OPT_MFDC}/${name}" 2>/dev/null || true
      restored=1
      # Откат — тоже смена бинарника: возвращённый runner прогоняет свой набор дельт (идемпотентных), и
      # остальные сервисы так же не должны стартовать раньше, чем он закончит.
      MFDC_UPDATED_BINS="${MFDC_UPDATED_BINS} ${name}"
    fi
  done

  if [[ -d "${backup_dir}/ui" ]] && [[ -f "${backup_dir}/ui/index.html" ]]; then
    do_it "restore UI → ${UI_WWW}"
    mkdir -p "${UI_WWW}"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete "${backup_dir}/ui/" "${UI_WWW}/"
    else
      find "${UI_WWW}" -mindepth 1 -delete 2>/dev/null || true
      cp -a "${backup_dir}/ui/." "${UI_WWW}/"
    fi
    chown -R www-data:www-data "${UI_WWW}" 2>/dev/null || true
    restored=1
  fi

  ((restored)) || die "в ${backup_dir} нет бинарников/UI для восстановления"

  if [[ -n "${MFDC_UPDATED_BINS}" ]]; then
    restart_mfdc_services "rollback"
  else
    ok "восстановлен только UI — рестарт mfdc-* не нужен"
  fi
  ok "откат выполнен из ${backup_dir}"
}

deploy_mfdc() {
  [[ "${SKIP_MFDC:-0}" == "1" ]] && { skip "MFDC apps"; return; }
  log "деплой MFDC → ${OPT_MFDC}"
  MFDC_APP_UPDATE=0
  MFDC_UI_UPDATE=0
  MFDC_UPDATED_BINS=""

  local bin_dir="${INSTALL_DIR}/bin"
  # бинарники уже проверены в require_prebuilt_artifacts — только копируем

  if ! getent passwd freeswitch >/dev/null; then
    die "нет пользователя freeswitch — сначала поставьте FreeSWITCH"
  fi

  mkdir -p "${OPT_MFDC}" /var/log/mfdc "${UI_WWW}"
  bash "${INSTALL_DIR}/systemd/install-mfdc-runtime.sh"
  # на случай если runtime-скрипт не отработал chown (или firewall перезаписал файлы от root)
  chown root:freeswitch "${OPT_MFDC}" 2>/dev/null || true
  chmod 2775 "${OPT_MFDC}" 2>/dev/null || true
  chown freeswitch:freeswitch /var/log/mfdc 2>/dev/null || true

  ensure_mfdc_logging
  ensure_freeswitch_logging

  local name
  for name in mfdc-api mfdc-broker mfdc-runner mfdc-caller mfdc-sniffer; do
    deploy_bin "$name" "${bin_dir}/${name}" "${OPT_MFDC}/${name}"
  done
  if [[ -f "${bin_dir}/mfdc-licence" ]]; then
    warn "bin/mfdc-licence найден, но не ставится клиенту (сервис продавца лицензий) — пропускаем"
  fi

  install_licence_public_key
  install_sip_public_addr

  if [[ -d "${INSTALL_DIR}/sniffer" ]]; then
    do_it "sniffer assets → ${OPT_MFDC}/sniffer"
    mkdir -p "${OPT_MFDC}/sniffer"
    cp -a "${INSTALL_DIR}/sniffer/." "${OPT_MFDC}/sniffer/"
    chown -R freeswitch:freeswitch "${OPT_MFDC}/sniffer"
  fi
  # ml.onnx рядом с бинарником (/opt/mfdc/ml.onnx) — так ищет mfdc-sniffer по умолчанию
  if [[ -f "${INSTALL_DIR}/sniffer/ml.onnx" ]]; then
    do_it "ml.onnx → ${OPT_MFDC}/ml.onnx"
    install -m 0644 "${INSTALL_DIR}/sniffer/ml.onnx" "${OPT_MFDC}/ml.onnx"
    chown freeswitch:freeswitch "${OPT_MFDC}/ml.onnx"
  elif [[ -f "${INSTALL_DIR}/ml.onnx" ]]; then
    do_it "ml.onnx → ${OPT_MFDC}/ml.onnx"
    install -m 0644 "${INSTALL_DIR}/ml.onnx" "${OPT_MFDC}/ml.onnx"
    chown freeswitch:freeswitch "${OPT_MFDC}/ml.onnx"
  fi
  if [[ -f "${OPT_MFDC}/mfdc-sniffer" ]]; then
    if [[ ! -f "${OPT_MFDC}/sniffer/libonnxruntime.so" ]] && ! ls "${OPT_MFDC}/sniffer"/libonnxruntime.so.* &>/dev/null; then
      warn "mfdc-sniffer без libonnxruntime.so — положите в install/sniffer/ перед pack/копированием"
    fi
    if [[ ! -f "${OPT_MFDC}/ml.onnx" ]]; then
      warn "mfdc-sniffer без ml.onnx — локальный AMD не заработает (положите в install/sniffer/ml.onnx)"
    fi
  fi

  if [[ -f "${OPT_MFDC}/settings.conf" ]] && [[ "$FORCE_CONFIG" != "1" ]]; then
    ok "settings.conf уже есть (FORCE_CONFIG=1 чтобы заменить)"
  else
    do_it "settings.conf → ${OPT_MFDC}/settings.conf"
    if [[ -f "${INSTALL_DIR}/settings.conf" ]]; then
      install -m 0640 "${INSTALL_DIR}/settings.conf" "${OPT_MFDC}/settings.conf"
    else
      cat > "${OPT_MFDC}/settings.conf" <<EOF
[postgresql]
host = ${MFDC_PG_HOST}
port = 5432
user = ${MFDC_PG_USER}
password = ${MFDC_PG_PASS}
dbname = ${MFDC_PG_DB}

[auth]
jwt_secret = $(openssl rand -hex 32)
reset_admin_passwd = true

[rabbitmq]
url = amqp://${MFDC_RABBIT_USER}:${MFDC_RABBIT_PASS}@127.0.0.1:5672/

[mfdc-api]
bind = 127.0.0.1:8001

[mfdc-broker]
bind = 127.0.0.1:9099

[mfdc-runner]
; Петля: сюда ходят локальные nginx и FreeSWITCH. На мультиноде расширьте и закройте файрволом.
bind = 127.0.0.1:8011
EOF
      chmod 0640 "${OPT_MFDC}/settings.conf"
    fi
  fi
  chown root:freeswitch "${OPT_MFDC}/settings.conf"
  chmod 0640 "${OPT_MFDC}/settings.conf"
  ensure_rabbitmq_url_in_settings
  ensure_jwt_secret_in_settings

  if [[ -d "${INSTALL_DIR}/ui" ]] && [[ -f "${INSTALL_DIR}/ui/index.html" ]]; then
    if ! ui_dist_complete "${INSTALL_DIR}/ui"; then
      warn "UI в пакете неполный (нет $(grep -oE '/assets/index-[A-Za-z0-9._-]+\.js' "${INSTALL_DIR}/ui/index.html" | head -1 || echo assets/index-*.js)) — ${UI_WWW} не трогаем"
    elif ui_tree_differs "${INSTALL_DIR}/ui" "${UI_WWW}"; then
      do_it "обновление UI → ${UI_WWW}"
      mkdir -p "${UI_WWW}"
      if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete "${INSTALL_DIR}/ui/" "${UI_WWW}/"
      else
        find "${UI_WWW}" -mindepth 1 -delete 2>/dev/null || true
        cp -a "${INSTALL_DIR}/ui/." "${UI_WWW}/"
      fi
      chown -R www-data:www-data "${UI_WWW}" 2>/dev/null || true
      MFDC_UI_UPDATE=1
    else
      ok "UI уже актуален (${UI_WWW})"
    fi
  else
    warn "UI не найден в ${INSTALL_DIR}/ui"
  fi

  # nginx + Let's Encrypt (домен из prompt_public_domain)
  deploy_nginx_and_tls

  do_it "systemd units mfdc-* (без mfdc-licence*)"
  # mfdc-licence / mfdc-licence-ui — только у продавца, клиенту не копируем
  local unit
  for unit in "${INSTALL_DIR}/systemd/"mfdc-*.service; do
    [[ -f "$unit" ]] || continue
    case "$(basename "$unit")" in
      mfdc-licence.service|mfdc-licence-ui.service|mfdc-landing.service) continue ;;
    esac
    install -m 0644 "$unit" /etc/systemd/system/
  done
  systemctl daemon-reload
  systemctl enable mfdc-runner mfdc-api mfdc-broker >/dev/null 2>&1 || true
  if [[ -f "${OPT_MFDC}/mfdc-caller" ]]; then
    systemctl enable mfdc-caller >/dev/null 2>&1 || true
  fi
  if [[ -f "${OPT_MFDC}/mfdc-sniffer" ]]; then
    systemctl enable mfdc-sniffer >/dev/null 2>&1 || true
  fi

  if (( MFDC_DEFER_START )); then
    ensure_stopped mfdc-runner
    ensure_stopped mfdc-api
    ensure_stopped mfdc-broker
    ensure_stopped mfdc-caller
    ensure_stopped mfdc-sniffer
    ok "unit-файлы mfdc-* установлены, сервисы не запускаем"
  elif [[ -n "${MFDC_UPDATED_BINS}" ]]; then
    restart_mfdc_services "обновление bin"
  elif (( MFDC_UI_UPDATE )); then
    ok "UI обновлён — рестарт mfdc-* не нужен (файлы отдаёт nginx)"
  elif ! svc_active mfdc-runner || ! svc_active mfdc-api || ! svc_active mfdc-broker; then
    restart_mfdc_services "сервисы не active — запуск"
  else
    ok "bin/ и UI без изменений — mfdc-* не перезапускаем"
  fi

  # OpenSIPS MFDC cfg нужен schema (location/…) — создаёт runner bootstrap
  restart_opensips_after_db

  # Система → Настройки (platform_settings) + directory.domains
  seed_install_platform_settings

  echo
  for u in freeswitch opensips rabbitmq-server postgresql nginx mfdc-runner mfdc-api mfdc-broker; do
    if systemctl cat "${u}.service" &>/dev/null; then
      if svc_active "$u"; then
        ok "$u active"
      elif (( MFDC_DEFER_START )); then
        ok "$u не запущен (установка не стартует сервисы)"
      else
        warn "$u НЕ active"
      fi
    fi
  done
}

# --- platform_settings + domain (после bootstrap mfdc-runner) -----------------
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

psql_mfdc() {
  PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" \
    -v ON_ERROR_STOP=1 "$@"
}

# Заполнить пустые ключи в system.platform_settings (не перезаписывает уже заданные).
seed_ps_set_text() {
  local path="$1" value="$2"   # path: {api,key}
  local qval
  qval="$(sql_quote "$value")"
  psql_mfdc -q -c "
    UPDATE system.platform_settings
    SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '${path}', to_jsonb('${qval}'::text), true),
        updated_at = NOW()
    WHERE id = 1
      AND COALESCE(settings #>> '${path}', '') = '';
  " >/dev/null
}

seed_ps_set_bool() {
  local path="$1" value="$2"  # true|false
  psql_mfdc -q -c "
    UPDATE system.platform_settings
    SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '${path}', to_jsonb(${value}::boolean), true),
        updated_at = NOW()
    WHERE id = 1
      AND (settings #> '${path}' IS NULL
           OR jsonb_typeof(settings #> '${path}') = 'null');
  " >/dev/null
}

seed_ps_set_json() {
  local path="$1" json="$2"
  psql_mfdc -q -c "
    UPDATE system.platform_settings
    SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '${path}', '${json}'::jsonb, true),
        updated_at = NOW()
    WHERE id = 1
      AND (settings #> '${path}' IS NULL
           OR settings #> '${path}' = 'null'::jsonb
           OR settings #> '${path}' = '[]'::jsonb
           OR settings #> '${path}' = '{}'::jsonb);
  " >/dev/null
}

api_key_is_placeholder() {
  local k="$1"
  [[ -z "$k" || "$k" == *MFDC_API_KEY* ]]
}

# Строка system.platform_settings до старта runner (идемпотентно; owner = MFDC_PG_USER).
ensure_platform_settings_row() {
  ensure_postgres_running || return 1
  psql_mfdc -q -c "
    CREATE SCHEMA IF NOT EXISTS system;
    CREATE TABLE IF NOT EXISTS system.platform_settings (
      id integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
      settings jsonb NOT NULL DEFAULT '{}'::jsonb,
      updated_at timestamptz NOT NULL DEFAULT now(),
      updated_by bigint
    );
    INSERT INTO system.platform_settings (id, settings)
    VALUES (1, '{}'::jsonb)
    ON CONFLICT (id) DO NOTHING;
  " >/dev/null || return 1
}

# Один ключ на установку: уже лежащий в БД, иначе из vars.xml (не плейсхолдер), иначе сгенерировать.
load_or_create_install_api_key() {
  local db_key="" vars_key="" key=""
  ensure_platform_settings_row || return 1
  db_key="$(psql_mfdc -tAc "SELECT COALESCE(settings#>>'{api,key}','') FROM system.platform_settings WHERE id=1" 2>/dev/null | tr -d '[:space:]' || true)"
  vars_key="$(sed -nE 's/.*data="mfdc_api_key=([^"]*)".*/\1/p' /etc/freeswitch/vars.xml 2>/dev/null | head -1 || true)"
  api_key_is_placeholder "$db_key" && db_key=""
  api_key_is_placeholder "$vars_key" && vars_key=""
  if [[ -n "$db_key" ]]; then
    key="$db_key"
  elif [[ -n "$vars_key" ]]; then
    key="$vars_key"
  else
    key="$(openssl rand -hex 32)"
  fi
  seed_ps_set_text '{api,key}' "$key" || return 1
  printf '%s' "$key"
}

# После копирования пакета: в vars.xml должен быть живой api.key, не __MFDC_API_KEY__.
apply_freeswitch_install_vars() {
  local key=""
  [[ -f /etc/freeswitch/vars.xml ]] || return 0
  key="$(load_or_create_install_api_key || true)"
  if api_key_is_placeholder "$key"; then
    key="$(openssl rand -hex 32)"
    warn "api.key не записан в БД — в vars.xml положен сгенерированный ключ; сверьте platform_settings"
  fi
  ensure_freeswitch_mfdc_api_key "$key"
  ensure_freeswitch_mfdc_sounds_dir
}

# Записать api.key в /etc/freeswitch/vars.xml как mfdc_api_key (для mod_xml_curl ?key=).
ensure_freeswitch_mfdc_api_key() {
  local key="$1"
  local vars="/etc/freeswitch/vars.xml"
  local cur=""
  [[ -n "$key" ]] || return 0
  if [[ ! -f "$vars" ]]; then
    warn "нет ${vars} — mfdc_api_key не записан (сначала deploy_freeswitch_conf)"
    return 0
  fi
  cur="$(sed -nE 's/.*data="mfdc_api_key=([^"]*)".*/\1/p' "$vars" 2>/dev/null | head -1 || true)"
  if [[ "$cur" == "$key" ]]; then
    ok "vars.xml: mfdc_api_key уже актуален"
    return 0
  fi
  if grep -qE 'mfdc_api_key=' "$vars"; then
    do_it "vars.xml: mfdc_api_key ← platform_settings api.key"
    sed -i -E "s|(data=\"mfdc_api_key=)[^\"]*(\")|\1${key}\2|" "$vars"
  else
    do_it "vars.xml: добавить mfdc_api_key"
    # вставить сразу после <include>
    sed -i "/<include>/a\\
  <X-PRE-PROCESS cmd=\"set\" data=\"mfdc_api_key=${key}\"/>" "$vars"
  fi
  chown freeswitch:freeswitch "$vars" 2>/dev/null || true
  if svc_active freeswitch; then
    fs_cli -x "reloadxml" >/dev/null 2>&1 || warn "fs_cli reloadxml не удался — рестартните freeswitch"
  fi
  ok "vars.xml: mfdc_api_key обновлён"
}

# Каталог медиатеки MFDC для local_stream://mfdc (platform MOH).
ensure_freeswitch_mfdc_sounds_dir() {
  local dir="${SOUNDS_DIR:-/var/lib/freeswitch/sounds/mfdc}"
  local vars="/etc/freeswitch/vars.xml"
  local cur=""
  mkdir -p "${dir}/_moh"
  chown freeswitch:freeswitch "${dir}" "${dir}/_moh" 2>/dev/null || true
  chmod 2775 "${dir}" 2>/dev/null || true
  [[ -f "$vars" ]] || return 0
  cur="$(sed -nE 's/.*data="mfdc_sounds_dir=([^"]*)".*/\1/p' "$vars" 2>/dev/null | head -1 || true)"
  if [[ "$cur" == "$dir" ]]; then
    ok "vars.xml: mfdc_sounds_dir уже актуален"
    return 0
  fi
  if grep -qE 'mfdc_sounds_dir=' "$vars"; then
    do_it "vars.xml: mfdc_sounds_dir ← ${dir}"
    sed -i -E "s|(data=\"mfdc_sounds_dir=)[^\"]*(\")|\1${dir}\2|" "$vars"
  else
    do_it "vars.xml: добавить mfdc_sounds_dir"
    sed -i "/mfdc_api_key=/a\\
  <X-PRE-PROCESS cmd=\"set\" data=\"mfdc_sounds_dir=${dir}\"/>" "$vars" 2>/dev/null \
      || sed -i "/<include>/a\\
  <X-PRE-PROCESS cmd=\"set\" data=\"mfdc_sounds_dir=${dir}\"/>" "$vars"
  fi
  chown freeswitch:freeswitch "$vars" 2>/dev/null || true
  if svc_active freeswitch; then
    fs_cli -x "reloadxml" >/dev/null 2>&1 || true
    fs_cli -x "local_stream reload mfdc" >/dev/null 2>&1 || true
  fi
  ok "vars.xml: mfdc_sounds_dir=${dir}"
}

# Одноразовая ротация заводского ESL-пароля: 'ClueCon' → сгенерированный, одновременно в
# system.platform_settings и в event_socket.conf.
#
# Почему именно так:
#   * обе стороны обязаны совпадать — пароль в БД, не совпадающий с паролем FreeSWITCH, кладёт
#     ВСЮ телефонию (брокер теряет ESL: originate, bridge, MOH, uuid_kill);
#   * конфиги FS установщик копирует только при ПЕРВОЙ установке (маркер .mfdc-installed),
#     поэтому правится РАЗВЁРНУТЫЙ файл — иначе на обновлении не поменялось бы ничего;
#   * меняем, только пока ОБЕ стороны на заводском значении. Свой пароль администратора не
#     трогаем, и повторные запуски install ничего не ротируют;
#   * на мультиноде пропускаем: у остальных нод свой event_socket.conf, до которого установщик
#     не дотянется, и правка локального конфига оборвала бы им ESL.
#
# Порядок записи: сначала правка во временный файл, потом БД, и только потом подмена файла —
# любой сбой оставляет обе стороны на прежнем согласованном значении.
ensure_freeswitch_esl_password() {
  local conf="/etc/freeswitch/configuration.xml"
  local cur_db="" cur_xml="" new_pass="" nodes=""

  cur_db="$(psql_mfdc -tAc \
    "SELECT COALESCE(settings#>>'{freeswitch,esl_password}','') FROM system.platform_settings WHERE id=1" \
    2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$cur_db" && "$cur_db" != "ClueCon" ]]; then
    ok "ESL: пароль задан администратором — не трогаем"
    return 0
  fi

  if [[ ! -f "$conf" ]]; then
    warn "ESL: ${conf} нет на этом хосте — пароль остаётся заводским; задайте его вручную в FreeSWITCH и в Настройки → FreeSWITCH"
    return 0
  fi

  # Текущее значение именно из секции event_socket.conf: <param name="password"> есть и в других.
  # `|| true` обязателен: скрипт под `set -euo pipefail`, и при pipefail любой сбой в конвейере
  # внутри присваивания уронил бы весь install.
  cur_xml="$(awk '/<configuration name="event_socket.conf"/,/<\/configuration>/' "$conf" \
    | sed -nE 's/.*<param name="password" value="([^"]*)".*/\1/p' | head -1 || true)"
  if [[ -z "$cur_xml" ]]; then
    warn "ESL: в event_socket.conf нет <param name=\"password\"> — пароль остаётся заводским"
    return 0
  fi
  if [[ "$cur_xml" != "ClueCon" ]]; then
    warn "ESL: в event_socket.conf свой пароль, а в platform_settings заводской — приведите их в соответствие вручную"
    return 0
  fi

  # На свежей установке system.fs_nodes может ещё не существовать (её раскатывает mfdc-runner):
  # пустой ответ = одна нода, а `|| true` не даёт pipefail уронить install на этом запросе.
  nodes="$(psql_mfdc -tAc \
    "SELECT COUNT(*) FROM system.fs_nodes WHERE enabled" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$nodes" ]] && (( nodes > 1 )); then
    warn "ESL: FS-нод ${nodes} — автоматическая смена пароля пропущена (у остальных нод свой event_socket.conf); задайте пароль на каждой ноде и в system.fs_nodes.esl_password"
    return 0
  fi

  new_pass="$(openssl rand -hex 24)"   # только hex: ниже он идёт в awk-замену и в XML-атрибут
  do_it "ESL: заводской пароль ClueCon → сгенерированный"

  awk -v pw="$new_pass" '
    /<configuration name="event_socket.conf"/ { ines = 1 }
    ines && /<param name="password"/ { sub(/value="[^"]*"/, "value=\"" pw "\"") }
    ines && /<\/configuration>/ { ines = 0 }
    { print }
  ' "$conf" > "${conf}.mfdc-new" || { warn "ESL: не удалось подготовить event_socket.conf — пароль не менялся"; rm -f "${conf}.mfdc-new"; return 0; }

  if ! grep -q "value=\"${new_pass}\"" "${conf}.mfdc-new"; then
    warn "ESL: замена в event_socket.conf не отработала — пароль не менялся"
    rm -f "${conf}.mfdc-new"
    return 0
  fi

  cp -p "$conf" "${conf}.mfdc-bak" 2>/dev/null || true
  if ! mv "${conf}.mfdc-new" "$conf"; then
    warn "ESL: не удалось заменить ${conf} — пароль не менялся"
    rm -f "${conf}.mfdc-new"
    return 0
  fi
  chown freeswitch:freeswitch "$conf" 2>/dev/null || true

  # БД — последней и с откатом файла при неудаче: рассинхрон половин дороже, чем незакрытая
  # заводская учётка, поэтому при любом сбое возвращаемся к согласованному 'ClueCon'.
  if ! psql_mfdc -q -c "
    UPDATE system.platform_settings
    SET settings = jsonb_set(COALESCE(settings, '{}'::jsonb), '{freeswitch,esl_password}',
                             to_jsonb('$(sql_quote "$new_pass")'::text), true),
        updated_at = NOW()
    WHERE id = 1;" >/dev/null; then
    warn "ESL: запись пароля в platform_settings не удалась — event_socket.conf возвращён"
    # if, а не `[[ … ]] && mv`: под set -e ложное условие в конце списка уронило бы скрипт.
    if [[ -f "${conf}.mfdc-bak" ]]; then
      mv "${conf}.mfdc-bak" "$conf"
    fi
    return 0
  fi
  rm -f "${conf}.mfdc-bak"

  if svc_active freeswitch; then
    # reloadxml не перечитывает mod_event_socket — нужен рестарт модуля.
    fs_cli -x "reload mod_event_socket" >/dev/null 2>&1 \
      || warn "ESL: fs_cli reload mod_event_socket не удался — рестартните freeswitch"
  fi
  # Рестарт mfdc-broker НЕ нужен: ESL-соединения создаются на каждую команду (shared/function/fs_esl.go),
  # а platform_settings разъезжаются по сервисам через pg_notify (platform_settings_listen.go).
  ok "ESL: пароль сгенерирован и синхронизирован с event_socket.conf"
}

seed_install_platform_settings() {
  [[ "${SKIP_MFDC:-0}" == "1" ]] && return
  [[ -n "${MFDC_DOMAIN}" ]] || { warn "MFDC_DOMAIN пуст — seed platform_settings пропущен"; return; }

  if (( MFDC_DEFER_START )); then
    skip "seed platform_settings на этапе установки (нет запущенного mfdc-runner)"
    return
  fi

  do_it "platform_settings + domain (${MFDC_DOMAIN})"

  mkdir -p "${RECORDINGS_DIR}" "${SOUNDS_DIR}" /var/cache/freeswitch
  chown freeswitch:freeswitch "${RECORDINGS_DIR}" "${SOUNDS_DIR}" /var/cache/freeswitch 2>/dev/null || true
  chmod 2775 "${RECORDINGS_DIR}" "${SOUNDS_DIR}" 2>/dev/null || true

  local i ready=0
  for i in $(seq 1 90); do
    if PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
      "SELECT 1 FROM information_schema.tables WHERE table_schema='system' AND table_name='platform_settings'" 2>/dev/null \
      | grep -qx 1; then
      ready=1
      break
    fi
    sleep 1
  done
  if ((!ready)); then
    warn "system.platform_settings ещё нет (90с) — seed пропущен; перезапустите install после mfdc-runner"
    return
  fi

  psql_mfdc -q -c "
    INSERT INTO system.platform_settings (id, settings, updated_at)
    VALUES (1, '{}'::jsonb, NOW())
    ON CONFLICT (id) DO NOTHING;
  " >/dev/null

  local api_key jwt_secret hmac_secret
  api_key="$(openssl rand -hex 32)"
  hmac_secret="$(openssl rand -hex 32)"
  # предпочитаем уже записанный в settings.conf jwt (ensure_jwt_secret_in_settings), иначе новый
  jwt_secret=""
  if [[ -f "${OPT_MFDC}/settings.conf" ]]; then
    jwt_secret="$(awk -F= '
      /^[[:space:]]*jwt_secret[[:space:]]*=/ {
        v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); gsub(/[[:space:]]+$/, "", v);
        if (v != "") { print v; exit }
      }' "${OPT_MFDC}/settings.conf" 2>/dev/null || true)"
  fi
  [[ -n "${jwt_secret}" ]] || jwt_secret="$(openssl rand -hex 32)"

  local scheme=wss cookie=true origin
  if [[ "${HTTP_ONLY}" == "1" ]] || [[ ! -f "/etc/letsencrypt/live/${MFDC_DOMAIN}/fullchain.pem" ]]; then
    scheme=ws
    cookie=false
    origin="http://${MFDC_DOMAIN}"
  else
    origin="https://${MFDC_DOMAIN}"
  fi
  local wss_url="${scheme}://${MFDC_DOMAIN}/wss/"
  local rabbit_url="amqp://${MFDC_RABBIT_USER}:${MFDC_RABBIT_PASS}@127.0.0.1:5672/"

  # --- api ---
  seed_ps_set_text '{api,key}' "${api_key}"
  seed_ps_set_text '{api,timezone}' "${MFDC_TIMEZONE}"
  seed_ps_set_bool '{api,debug_mode}' false
  seed_ps_set_text '{api,opensips_sip_addr}' 'sip:127.0.0.1:6062'
  seed_ps_set_text '{api,opensips_jrpc_url}' 'http://127.0.0.1:8000/mi'
  seed_ps_set_text '{api,webrtc_wss_url}' "${wss_url}"
  seed_ps_set_text '{api,webrtc_sip_domain}' "${MFDC_DOMAIN}"
  seed_ps_set_text '{api,webrtc_via_transport}' "${scheme}"

  # --- auth ---
  seed_ps_set_text '{auth,jwt_secret}' "${jwt_secret}"
  seed_ps_set_bool '{auth,cookie_secure}' "${cookie}"
  seed_ps_set_text '{auth,cookie_samesite}' 'lax'
  seed_ps_set_text '{auth,mfa_issuer}' 'MFDC'
  seed_ps_set_json '{auth,cors_allowed_origins}' "[\"$(sql_quote "${origin}")\"]"

  # --- recordings / sounds (IVR-MOH + runner URL) ---
  seed_ps_set_bool '{recordings,enabled}' true
  seed_ps_set_text '{recordings,directory}' "${RECORDINGS_DIR}"
  seed_ps_set_text '{recordings,url_base}' '/api/cdr'
  seed_ps_set_text '{recordings,lame_path}' 'lame'
  seed_ps_set_bool '{recordings,keep_wav}' true

  seed_ps_set_text '{sounds,directory}' "${SOUNDS_DIR}"
  seed_ps_set_text '{sounds,ffmpeg_path}' 'ffmpeg'
  seed_ps_set_text '{sounds,playback_url_base}' "${PLAYBACK_URL_BASE}"
  seed_ps_set_bool '{sounds,sync_enabled}' true

  # --- rabbitmq / freeswitch ---
  seed_ps_set_text '{rabbitmq,url}' "${rabbit_url}"
  seed_ps_set_text '{rabbitmq,caller_command_hmac_secret}' "${hmac_secret}"
  # ESL: заводское значение на случай, если ротация ниже не сможет отработать. Генерацию делает
  # ensure_freeswitch_esl_password — только вместе с правкой event_socket.conf, потому что
  # пароль в БД, не совпадающий с паролем FreeSWITCH, кладёт ВСЮ телефонию.
  seed_ps_set_text '{freeswitch,esl_password}' 'ClueCon'
  seed_ps_set_text '{freeswitch,http_cache_dir}' '/var/cache/freeswitch'
  seed_ps_set_text '{freeswitch,http_cache_owner}' 'freeswitch'

  # --- domain (тот же FQDN что Let's Encrypt / WebRTC) ---
  local qdom qorg
  qdom="$(sql_quote "${MFDC_DOMAIN}")"
  qorg="$(sql_quote "MFDC")"
  psql_mfdc -q -c "
    INSERT INTO directory.domains (domain, organization, country)
    SELECT '${qdom}', '${qorg}', 'KZ'
    WHERE NOT EXISTS (
      SELECT 1 FROM directory.domains WHERE LOWER(TRIM(domain)) = LOWER(TRIM('${qdom}'))
    );
  " >/dev/null

  # показать факт заполнения (секреты не целиком)
  local key_set jwt_set dom_id
  key_set="$(PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
    "SELECT CASE WHEN COALESCE(settings#>>'{api,key}','') <> '' THEN 'yes' ELSE 'no' END FROM system.platform_settings WHERE id=1" 2>/dev/null | tr -d '[:space:]')"
  jwt_set="$(PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
    "SELECT CASE WHEN COALESCE(settings#>>'{auth,jwt_secret}','') <> '' THEN 'yes' ELSE 'no' END FROM system.platform_settings WHERE id=1" 2>/dev/null | tr -d '[:space:]')"
  dom_id="$(PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
    "SELECT id FROM directory.domains WHERE LOWER(TRIM(domain))=LOWER(TRIM('${qdom}')) LIMIT 1" 2>/dev/null | tr -d '[:space:]')"

  ok "platform_settings: api.key=${key_set} jwt_secret=${jwt_set} webrtc=${wss_url}"
  ok "recordings=${RECORDINGS_DIR}  sounds(IVR/MOH)=${SOUNDS_DIR}"
  ok "playback_url_base=${PLAYBACK_URL_BASE}"
  ok "directory.domains: ${MFDC_DOMAIN} (id=${dom_id:-?})"

  # api.key в БД → FreeSWITCH vars.xml (seed_ps_set_text не перезаписывает уже заданный)
  local effective_key
  effective_key="$(PGPASSWORD="${MFDC_PG_PASS}" psql -h "${MFDC_PG_HOST}" -U "${MFDC_PG_USER}" -d "${MFDC_PG_DB}" -tAc \
    "SELECT COALESCE(settings#>>'{api,key}','') FROM system.platform_settings WHERE id=1" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$effective_key" ]] || effective_key="${api_key}"
  ensure_freeswitch_mfdc_api_key "$effective_key"
  ensure_freeswitch_mfdc_sounds_dir
  ensure_freeswitch_esl_password

  # после записи platform_settings — рестарт api/broker только если сменился бинарник
  if [[ -n "${MFDC_UPDATED_BINS}" ]]; then
    systemctl restart mfdc-api mfdc-broker 2>/dev/null || true
  fi
}

# --- nginx + Let's Encrypt ---------------------------------------------------
write_webrtc_settings() {
  # $1: 1=HTTPS/WSS+cookie_secure (default), 0=HTTP/WS lab
  local conf="${OPT_MFDC}/settings.conf"
  local secure="${1:-1}"
  local scheme=wss cookie=true
  if [[ "$secure" != "1" ]]; then
    scheme=ws
    cookie=false
  fi
  local wss="${scheme}://${MFDC_DOMAIN}/wss/"
  [[ -n "${MFDC_DOMAIN}" ]] || { warn "MFDC_DOMAIN пуст — webrtc settings пропущены"; return 0; }
  [[ -f "$conf" ]] || { warn "нет $conf"; return 0; }
  if grep -qE '^\[api\]' "$conf"; then
    if grep -qE '^[[:space:]]*webrtc_wss_url[[:space:]]*=' "$conf"; then
      sed -i -E "s|^[[:space:]]*webrtc_wss_url[[:space:]]*=.*|webrtc_wss_url = ${wss}|" "$conf"
    else
      sed -i "/^\[api\]/a webrtc_wss_url = ${wss}" "$conf"
    fi
    if grep -qE '^[[:space:]]*webrtc_sip_domain[[:space:]]*=' "$conf"; then
      sed -i -E "s|^[[:space:]]*webrtc_sip_domain[[:space:]]*=.*|webrtc_sip_domain = ${MFDC_DOMAIN}|" "$conf"
    else
      sed -i "/^\[api\]/a webrtc_sip_domain = ${MFDC_DOMAIN}" "$conf"
    fi
    if grep -qE '^[[:space:]]*webrtc_via_transport[[:space:]]*=' "$conf"; then
      sed -i -E "s|^[[:space:]]*webrtc_via_transport[[:space:]]*=.*|webrtc_via_transport = ${scheme}|" "$conf"
    else
      sed -i "/^\[api\]/a webrtc_via_transport = ${scheme}" "$conf"
    fi
  else
    cat >> "$conf" <<EOF

[api]
webrtc_wss_url = ${wss}
webrtc_sip_domain = ${MFDC_DOMAIN}
webrtc_via_transport = ${scheme}
EOF
  fi
  if grep -qE '^\[auth\]' "$conf"; then
    if grep -qE '^[[:space:]]*cookie_secure[[:space:]]*=' "$conf"; then
      sed -i -E "s|^[[:space:]]*cookie_secure[[:space:]]*=.*|cookie_secure = ${cookie}|" "$conf"
    else
      sed -i "/^\[auth\]/a cookie_secure = ${cookie}" "$conf"
    fi
  fi
  ok "settings.conf: webrtc_wss_url=${wss} cookie_secure=${cookie}"
}

deploy_nginx_http_bootstrap() {
  mkdir -p /etc/nginx/snippets "${ACME_WWW}/.well-known/acme-challenge" "${UI_WWW}"
  chown -R www-data:www-data "${ACME_WWW}" 2>/dev/null || true

  install_lf "${INSTALL_DIR}/nginx/mfdc-api-proxy.conf" /etc/nginx/snippets/mfdc-api-proxy.conf 0644
  do_it "nginx HTTP bootstrap (ACME) для ${MFDC_DOMAIN}"
  install_lf "${INSTALL_DIR}/nginx/mfdc-ui-http.conf" /etc/nginx/sites-available/mfdc-ui.conf 0644
  # server_name _ → домен (в http-шаблоне default_server / _)
  if grep -q 'server_name _;' /etc/nginx/sites-available/mfdc-ui.conf; then
    sed -i "s/server_name _;/server_name ${MFDC_DOMAIN};/" /etc/nginx/sites-available/mfdc-ui.conf
  fi
  # гарантируем ACME root
  if ! grep -q 'acme-challenge' /etc/nginx/sites-available/mfdc-ui.conf; then
    warn "в http-шаблоне нет acme-challenge — добавьте вручную"
  else
    sed -i "s|root /var/www/certbot;|root ${ACME_WWW};|g" /etc/nginx/sites-available/mfdc-ui.conf
  fi
  ln -sfn /etc/nginx/sites-available/mfdc-ui.conf /etc/nginx/sites-enabled/mfdc-ui.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  ensure_stopped nginx
  ok "nginx HTTP-конфиг записан (сервис не запускаем)"
}

deploy_nginx_ssl() {
  local live="/etc/letsencrypt/live/${MFDC_DOMAIN}"
  [[ -f "${live}/fullchain.pem" && -f "${live}/privkey.pem" ]] || die "нет сертификата в ${live}"

  mkdir -p /etc/nginx/snippets "${ACME_WWW}/.well-known/acme-challenge" "${UI_WWW}"
  do_it "nginx HTTPS + WSS для ${MFDC_DOMAIN}"
  install_lf "${INSTALL_DIR}/nginx/mfdc-ui.conf" /etc/nginx/sites-available/mfdc-ui.conf 0644
  sed -i "s/mfdc.example.com/${MFDC_DOMAIN}/g" /etc/nginx/sites-available/mfdc-ui.conf
  sed -i "s|root /var/www/certbot;|root ${ACME_WWW};|g" /etc/nginx/sites-available/mfdc-ui.conf

  if [[ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]]; then
    mkdir -p /etc/letsencrypt
    cat > /etc/letsencrypt/options-ssl-nginx.conf <<'EOF'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;
EOF
  fi
  if [[ ! -f /etc/letsencrypt/ssl-dhparams.pem ]]; then
    # убрать строку dhparam, если файла нет (не блокируем установку)
    sed -i '/ssl_dhparam/d' /etc/nginx/sites-available/mfdc-ui.conf
  fi

  ln -sfn /etc/nginx/sites-available/mfdc-ui.conf /etc/nginx/sites-enabled/mfdc-ui.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx >/dev/null 2>&1 || true
  ensure_stopped nginx
  ok "HTTPS-конфиг записан https://${MFDC_DOMAIN}/  (nginx не запускаем)"
}

# Раскладка как у certbot: archive/<домен>/fullchain1.pem + privkey1.pem
# и символические ссылки live/<домен>/{fullchain,privkey}.pem — nginx не меняем.
install_bundled_letsencrypt() {
  local src archive live
  src="$(bundled_le_cert_dir)"
  [[ -s "${src}/fullchain1.pem" && -s "${src}/privkey1.pem" ]] || \
    die "нет ${src}/fullchain1.pem и privkey1.pem"

  if ! grep -q "BEGIN CERTIFICATE" "${src}/fullchain1.pem"; then
    die "${src}/fullchain1.pem не похож на сертификат PEM"
  fi
  if ! grep -qE 'BEGIN ([A-Z]+ )?PRIVATE KEY' "${src}/privkey1.pem"; then
    die "${src}/privkey1.pem не похож на закрытый ключ PEM"
  fi

  archive="/etc/letsencrypt/archive/${MFDC_DOMAIN}"
  live="/etc/letsencrypt/live/${MFDC_DOMAIN}"
  do_it "сертификат ${MFDC_DOMAIN} из install/cert/ → ${live}"
  mkdir -p /etc/letsencrypt/archive /etc/letsencrypt/live
  chmod 0755 /etc/letsencrypt /etc/letsencrypt/live
  chmod 0700 /etc/letsencrypt/archive
  mkdir -p "${archive}" "${live}"
  chmod 0755 "${archive}" "${live}"

  install_lf "${src}/fullchain1.pem" "${archive}/fullchain1.pem" 0644
  install_lf "${src}/privkey1.pem" "${archive}/privkey1.pem" 0600
  ln -sfn "../../archive/${MFDC_DOMAIN}/fullchain1.pem" "${live}/fullchain.pem"
  ln -sfn "../../archive/${MFDC_DOMAIN}/privkey1.pem" "${live}/privkey.pem"
  cat > "${live}/README" <<EOF
This certificate was installed by MFDC install.sh from install/cert/
(fullchain1.pem + privkey1.pem), same layout as certbot:
  ${archive}/fullchain1.pem
  ${archive}/privkey1.pem
  ${live}/fullchain.pem -> ../../archive/${MFDC_DOMAIN}/fullchain1.pem
  ${live}/privkey.pem   -> ../../archive/${MFDC_DOMAIN}/privkey1.pem
Not managed by certbot.timer. To renew: replace install/cert/ and re-run
LE_ISSUE=0 bash install.sh, or issue a new cert with LE_ISSUE=1.
EOF
  chmod 0644 "${live}/README"

  if command -v openssl >/dev/null 2>&1; then
    local subj
    subj="$(openssl x509 -noout -subject -in "${archive}/fullchain1.pem" 2>/dev/null || true)"
    [[ -n "${subj}" ]] && ok "сертификат: ${subj}"
    if ! openssl x509 -noout -checkend 86400 -in "${archive}/fullchain1.pem" >/dev/null 2>&1; then
      warn "сертификат истекает менее чем через сутки или уже истёк"
    fi
  fi
  ok "live: ${live}/fullchain.pem → archive/${MFDC_DOMAIN}/fullchain1.pem"
}

setup_letsencrypt() {
  [[ "${HTTP_ONLY}" == "1" || "${SKIP_LE}" == "1" ]] && { skip "Let's Encrypt"; return 1; }

  if [[ "${LE_ISSUE}" == "0" ]]; then
    install_bundled_letsencrypt
    return 0
  fi

  do_it "certbot для ${MFDC_DOMAIN}"
  apt-get install -y -qq certbot
  mkdir -p "${ACME_WWW}/.well-known/acme-challenge"
  chown -R www-data:www-data "${ACME_WWW}" 2>/dev/null || true
  ensure_stopped nginx

  # standalone: nginx не держим запущенным, порт 80 свободен.
  if certbot certonly --standalone \
      -d "${MFDC_DOMAIN}" \
      --email "${LE_EMAIL}" \
      --agree-tos --non-interactive --keep-until-expiring \
      --preferred-challenges http; then
    ok "Let's Encrypt: сертификат выпущен/обновлён"
    systemctl enable certbot.timer 2>/dev/null || true
    return 0
  fi
  warn "certbot не смог выпустить сертификат — проверьте DNS A-запись ${MFDC_DOMAIN} → этот сервер и порт 80"
  return 1
}

deploy_nginx_and_tls() {
  mkdir -p /etc/nginx/snippets
  install_lf "${INSTALL_DIR}/nginx/mfdc-api-proxy.conf" /etc/nginx/snippets/mfdc-api-proxy.conf 0644

  if [[ "${HTTP_ONLY}" == "1" ]]; then
    do_it "nginx HTTP only (HTTP_ONLY=1)"
    install_lf "${INSTALL_DIR}/nginx/mfdc-ui-http.conf" /etc/nginx/sites-available/mfdc-ui.conf 0644
    if [[ -n "${MFDC_DOMAIN}" ]]; then
      sed -i "s/server_name _;/server_name ${MFDC_DOMAIN};/" /etc/nginx/sites-available/mfdc-ui.conf || true
    fi
    ln -sfn /etc/nginx/sites-available/mfdc-ui.conf /etc/nginx/sites-enabled/mfdc-ui.conf
    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl enable nginx >/dev/null 2>&1 || true
    ensure_stopped nginx
    # lab: ws:// + cookie_secure=false (не wss/Secure на HTTP)
    write_webrtc_settings 0 || true
    return
  fi

  # Готовый сертификат из install/cert/ — без ACME на порту 80.
  if [[ "${LE_ISSUE}" == "0" ]]; then
    if setup_letsencrypt; then
      deploy_nginx_ssl
      write_webrtc_settings 1
    else
      die "не удалось положить сертификат из install/cert/"
    fi
    return
  fi

  # 1) сертификат (standalone — nginx не нужен)
  # 2) HTTPS-конфиг на диск
  if setup_letsencrypt; then
    deploy_nginx_ssl
    write_webrtc_settings 1
  else
    warn "оставлен HTTP-конфиг — после исправления DNS: FORCE_CONFIG=1 bash install.sh"
    deploy_nginx_http_bootstrap
    write_webrtc_settings 0 || true
  fi
}

start_install_stack() {
  log "запуск стека (OpenSIPS — после транков и внутренних номеров)"
  MFDC_DEFER_START=0

  start_unit_report postgresql
  if ! svc_active postgresql && ! svc_active postgresql@17-main; then
    systemctl start postgresql@17-main 2>/dev/null || true
    if svc_active postgresql@17-main; then
      ok "postgresql@17-main active"
    else
      warn "postgresql НЕ active"
    fi
  fi

  start_unit_report rabbitmq-server
  ensure_rabbitmq_user

  start_unit_report mfdc-runner
  wait_for_mfdc_runner_schema
  seed_install_platform_settings

  start_unit_report freeswitch
  if systemctl cat ngcp-rtpengine-daemon.service &>/dev/null; then
    start_unit_report ngcp-rtpengine-daemon
  else
    start_unit_report rtpengine
  fi
  start_unit_report nginx
  start_unit_report mfdc-api
  start_unit_report mfdc-broker
  if [[ -f "${OPT_MFDC}/mfdc-caller" ]]; then
    start_unit_report mfdc-caller
  fi
  if [[ -f "${OPT_MFDC}/mfdc-sniffer" ]]; then
    start_unit_report mfdc-sniffer
  fi

  if [[ "$FORCE_RESTART" == "1" ]]; then
    restart_opensips_after_db
  else
    systemctl disable --now opensips >/dev/null 2>&1 || true
    ensure_stopped opensips
    skip "OpenSIPS не запущен — после транков и номеров: systemctl enable --now opensips"
  fi
}

# --- Docker ------------------------------------------------------------------
# Docker + ML поднимаются при установке, если ещё не running (не ждут FORCE_RESTART).
ensure_docker_running() {
  command -v docker >/dev/null 2>&1 || return 1
  systemctl enable docker >/dev/null 2>&1 || true
  if svc_active docker; then
    return 0
  fi
  do_it "systemctl start docker"
  systemctl start docker || { warn "docker не стартовал"; return 1; }
}

install_docker() {
  [[ "${SKIP_DOCKER:-0}" == "1" ]] && { skip "Docker"; return; }

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker + compose уже установлены ($(docker --version | head -1))"
    ensure_docker_running || true
    return
  fi

  do_it "Docker Engine (официальный apt bookworm)"
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
  fi
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  ensure_docker_running || warn "docker не стартовал"
  ok "Docker установлен"
}

# --- ML sidecars (whisper + topic-classifier) ---------------------------------
ml_container_is_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || echo false)" == "true" ]]
}

# $1=compose dir, $2=container_name, $3=label for logs
# Поднимаем сразу при установке, если контейнер ещё не running (MFDC_DEFER_START не касается ML).
ensure_ml_compose() {
  local dir="$1" name="$2" label="$3"
  if ml_container_is_running "${name}"; then
    ok "${label} уже запущен — не трогаем"
    return 0
  fi
  [[ -f "${dir}/docker-compose.yml" ]] || { warn "нет ${dir}/docker-compose.yml"; return 0; }
  ensure_docker_running || { warn "docker не running — ${label} не поднимаем"; return 0; }
  log "сборка/запуск ${label}"
  (
    cd "${dir}"
    docker compose up -d --build
  ) || warn "${label} compose failed"
}

install_ml() {
  [[ "${SKIP_ML:-0}" == "1" ]] && { skip "ML"; return; }
  [[ "${SKIP_DOCKER:-0}" == "1" ]] && { warn "SKIP_DOCKER=1 — ML не ставятся"; return; }

  if [[ ! -d "${INSTALL_DIR}/ml/whisper" ]] || [[ ! -f "${INSTALL_DIR}/ml/whisper/docker-compose.yml" ]]; then
    warn "нет install/ml/whisper — пропуск ML"
    return
  fi
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker не найден — ML не ставятся"
    return
  fi
  ensure_docker_running || { warn "docker не running — ML не ставятся"; return; }

  do_it "копирование ML compose → ${ML_DIR}"
  mkdir -p "${ML_DIR}"
  cp -a "${INSTALL_DIR}/ml/." "${ML_DIR}/"

  ensure_ml_compose "${ML_DIR}/whisper" "mfdc-whisper" "mfdc-whisper"

  if [[ -d "${ML_DIR}/topic-classifier" ]] && [[ -f "${ML_DIR}/topic-classifier/docker-compose.yml" ]]; then
    ensure_ml_compose "${ML_DIR}/topic-classifier" "mfdc-topic-classifier" "mfdc-topic-classifier"
  else
    warn "нет topic-classifier в пакете"
  fi

  # health checks (не валим install)
  sleep 2
  if curl -sf http://127.0.0.1:9600/healthz >/dev/null 2>&1; then
    ok "mfdc-whisper healthz OK (:9600)"
  else
    warn "mfdc-whisper ещё не отвечает на :9600 (модель может грузиться)"
  fi
  if curl -sf http://127.0.0.1:9601/healthz >/dev/null 2>&1; then
    ok "mfdc-topic-classifier healthz OK (:9601)"
  else
    warn "mfdc-topic-classifier ещё не отвечает на :9601"
  fi
  ok "ML URLs для UI: http://127.0.0.1:9600  и  http://127.0.0.1:9601"
}

# --- nftables firewall -------------------------------------------------------
detect_ssh_ports() {
  if [[ -n "${MFDC_SSH_PORTS:-}" && "${MFDC_SSH_PORTS}" != "auto" ]]; then
    echo "${MFDC_SSH_PORTS}" | tr -d '[:space:]'
    return
  fi
  local found=()
  local p
  # порт текущей SSH-сессии (4-е поле SSH_CONNECTION) — защита от lockout
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    p="$(echo "$SSH_CONNECTION" | awk '{print $4}')"
    [[ "$p" =~ ^[0-9]+$ ]] && found+=("$p")
  fi
  for p in 22 8822; do
    if ss -tln 2>/dev/null | grep -qE ":${p}\\s"; then
      local already=0 x
      for x in "${found[@]+"${found[@]}"}"; do
        [[ "$x" == "$p" ]] && already=1 && break
      done
      ((already)) || found+=("$p")
    fi
  done
  if ((${#found[@]})); then
    local IFS=,
    echo "${found[*]}"
  else
    echo "22,8822"
  fi
}

# Собирает IPv4/IPv6 CIDR для SIP allow-list → пишет /etc/mfdc/sip_allow.list.
# Применение в nft — через /opt/mfdc/reload-sip-allow.sh (файловая подстановка, большие списки).
# Принимает: один CIDR на строку ИЛИ список через запятую в одной строке.
collect_sip_allow() {
  local list_src="${SIP_ALLOW_LIST:-${INSTALL_DIR}/nftables/sip_allow.list}"
  local out_list="/etc/mfdc/sip_allow.list"
  local entries=()
  local line e part

  mkdir -p /etc/mfdc

  # разбить строку/кусок на отдельные CIDR (запятые, пробелы, CR)
  sip_allow_push() {
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw//,/ }"
    for part in $raw; do
      part="$(printf '%s' "$part" | tr -d '[:space:]\r')"
      [[ -n "$part" ]] && entries+=("$part")
    done
  }

  if [[ -n "${SIP_ALLOW}" ]]; then
    sip_allow_push "${SIP_ALLOW}"
  else
    local candidates=()
    [[ -f "$out_list" ]] && candidates+=("$out_list")
    [[ -f "$list_src" ]] && candidates+=("$list_src")
    local srcf
    for srcf in "${candidates[@]+"${candidates[@]}"}"; do
      entries=()
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line//$'\r'/}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        sip_allow_push "$line"
      done < "$srcf"
      ((${#entries[@]})) && break
    done
  fi

  if ((${#entries[@]} == 0)); then
    if [[ ! -t 0 ]]; then
      die "нет SIP allow-list (non-interactive). Задайте SIP_ALLOW=1.2.3.4,5.6.7.0/24 или заполните ${list_src}"
    fi
    echo
    echo "SIP на публичном сервере должен быть доступен ТОЛЬКО провайдерам и офису."
    echo "Укажите внешние IP/подсети (CIDR), с которых разрешён SIP → OpenSIPS."
    echo "WebRTC (операторы в браузере) идёт через :443/WSS — сюда не нужно."
    echo "Можно: один CIDR на строку ИЛИ несколько через запятую."
    echo "Пустая строка — конец ввода. Пример: 203.0.113.10,198.51.100.0/24"
    while true; do
      read -r -p "SIP allow CIDR: " line || true
      line="${line:-}"
      line="${line//$'\r'/}"
      [[ -z "${line//[[:space:]]/}" ]] && break
      sip_allow_push "$line"
    done
  fi

  ((${#entries[@]})) || die "нужен хотя бы один SIP allow (SIP_ALLOW=... или ${list_src})"

  # дедуп с сохранением порядка
  local uniq=() seen
  for e in "${entries[@]}"; do
    seen=0
    for part in "${uniq[@]+"${uniq[@]}"}"; do
      [[ "$part" == "$e" ]] && { seen=1; break; }
    done
    ((seen)) || uniq+=("$e")
  done
  entries=("${uniq[@]}")

  {
    echo "# Generated by install.sh — SIP sources for OpenSIPS/FS signaling"
    echo "# Edit and run: bash /opt/mfdc/reload-sip-allow.sh"
    for e in "${entries[@]}"; do
      echo "$e"
    done
  } > "$out_list"
  chmod 0644 "$out_list"

  local v4=() v6=()
  for e in "${entries[@]}"; do
    if [[ "$e" == *:* ]]; then
      v6+=("$e")
    else
      v4+=("$e")
    fi
  done
  ((${#v4[@]})) || die "нужен хотя бы один IPv4 в SIP allow-list (сейчас только IPv6?)"

  ok "SIP allow: ${#v4[@]} IPv4, ${#v6[@]} IPv6 → ${out_list}"
  # Применение в nft — через reload-sip-allow.sh (файловая подстановка).
  SIP_ALLOW4_ELEMENTS=""
  SIP_ALLOW6_ELEMENTS=""
}

# Гарантировать: /etc/nftables.conf с MFDC грузится при boot; docker/rtpengine/sshguard — после него.
ensure_nftables_persist() {
  [[ -f /etc/nftables.conf ]] || { warn "нет /etc/nftables.conf"; return 0; }
  if ! grep -q 'MFDC host firewall' /etc/nftables.conf 2>/dev/null; then
    warn "/etc/nftables.conf без маркера MFDC — после reboot firewall не восстановится; FORCE_CONFIG=1 или reload-sip-allow.sh"
  fi

  systemctl unmask nftables 2>/dev/null || true
  systemctl enable nftables >/dev/null 2>&1 || true

  # Boot order: nftables (flush + MFDC) → docker / rtpengine / sshguard
  local dropin_dir unit
  for unit in docker.service ngcp-rtpengine-daemon.service rtpengine.service sshguard.service; do
    systemctl cat "${unit}" &>/dev/null || continue
    dropin_dir="/etc/systemd/system/${unit}.d"
    mkdir -p "$dropin_dir"
    cat > "${dropin_dir}/mfdc-after-nftables.conf" <<'EOF'
[Unit]
# MFDC: /etc/nftables.conf делает flush ruleset — сервисы с iptables/nft-цепями
# должны стартовать ПОСЛЕ nftables, иначе их правила пропадут при reboot.
After=nftables.service
Wants=nftables.service
EOF
  done
  systemctl daemon-reload 2>/dev/null || true

  if systemctl is-enabled nftables >/dev/null 2>&1; then
    ok "nftables enabled on boot (After= для docker/rtpengine/sshguard)"
  else
    warn "nftables НЕ enabled — после reboot MFDC firewall пропадёт: systemctl enable --now nftables"
  fi
}

install_firewall() {
  [[ "${SKIP_FIREWALL:-0}" == "1" ]] && { skip "nftables"; return; }

  local src="${INSTALL_DIR}/nftables/nftables.mfdc.conf.tpl"
  [[ -f "$src" ]] || { warn "нет $src"; return; }

  collect_sip_allow

  do_it "nftables (deny + SIP allow-list)"
  apt-get install -y -qq nftables
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi active; then
    warn "отключаем ufw (конфликт с nftables)"
    ufw disable || true
  fi
  systemctl disable --now ufw 2>/dev/null || true

  # шаблон + reload-скрипт на диск (всегда LF — CRLF с Windows ломает nft)
  mkdir -p /etc/mfdc /opt/mfdc
  tr -d '\r' < "$src" > /etc/mfdc/nftables.mfdc.conf.tpl
  chmod 0644 /etc/mfdc/nftables.mfdc.conf.tpl
  if [[ -f "${INSTALL_DIR}/nftables/reload-sip-allow.sh" ]]; then
    tr -d '\r' < "${INSTALL_DIR}/nftables/reload-sip-allow.sh" > /opt/mfdc/reload-sip-allow.sh
    chmod 0755 /opt/mfdc/reload-sip-allow.sh
    # не оставлять /opt/mfdc root:root после записи файла
    chown root:freeswitch /opt/mfdc 2>/dev/null || true
    chmod 2775 /opt/mfdc 2>/dev/null || true
  fi

  local ports ports_file
  ports="$(detect_ssh_ports)"
  ports="$(echo "$ports" | tr -d '[:space:]\r' | sed 's/,/, /g')"
  ports_file="/etc/mfdc/ssh_ports"
  echo "$(echo "$ports" | tr -d '[:space:]')" > "$ports_file"
  chmod 0644 "$ports_file"

  # Подстановка большого SIP-списка — только через reload-sip-allow.sh (без sed ARG_MAX).
  if [[ ! -x /opt/mfdc/reload-sip-allow.sh ]]; then
    die "нет /opt/mfdc/reload-sip-allow.sh — нечем применить SIP allow-list"
  fi
  if [[ -f /etc/nftables.conf ]] && [[ "$FORCE_CONFIG" != "1" ]] && grep -q 'MFDC host firewall' /etc/nftables.conf 2>/dev/null \
     && grep -q 'sip_allow4' /etc/nftables.conf 2>/dev/null; then
    ok "nftables MFDC уже применён — обновляем SIP allow-list (SSH ports: ${ports_file})"
  else
    if [[ -f /etc/nftables.conf ]] && [[ ! -f /etc/nftables.conf.mfdc-bak ]]; then
      cp -a /etc/nftables.conf /etc/nftables.conf.mfdc-bak
    fi
  fi
  MFDC_SSH_PORTS="$(tr -d '[:space:]' < "$ports_file")" \
    bash /opt/mfdc/reload-sip-allow.sh \
    || die "reload-sip-allow.sh не применился"
  ok "nftables active (SSH: ${ports}; SIP only from allow-list)"

  ensure_nftables_persist

  # reload-sip-allow.sh уже сделал nft -f + restart docker (цепочки DOCKER).
  # Повторный restart здесь только если демон не поднялся; compose — в install_ml после firewall.
  if command -v docker >/dev/null 2>&1 && systemctl is-enabled docker >/dev/null 2>&1; then
    if ! svc_active docker; then
      do_it "start docker (после nft)"
      systemctl start docker || warn "docker не стартовал"
    fi
  fi

  if command -v sshguard >/dev/null 2>&1 || pkg_installed sshguard; then
    systemctl restart sshguard 2>/dev/null || true
  fi

  # flush ruleset сносит nft-цепи rtpengine — пересоздаём после firewall
  if [[ "${SKIP_RTPENGINE:-0}" != "1" ]]; then
    ensure_rtpengine_kernel
    # table в conf мог остаться 0 при отсутствии модуля — синхронизируем
    if [[ -f /etc/rtpengine/rtpengine.conf ]]; then
      if rtpengine_kernel_ready; then
        sed -i -E 's|^[[:space:]]*table[[:space:]]*=.*|table = 0|' /etc/rtpengine/rtpengine.conf
      else
        sed -i -E 's|^[[:space:]]*table[[:space:]]*=.*|table = -1|' /etc/rtpengine/rtpengine.conf
      fi
    fi
    do_it "restart rtpengine (nft chains после firewall)"
    restart_rtpengine
  fi

  warn "SSH: запасная сессия! Порты ${ports}; 80/443/8008+SIP только из /etc/mfdc/sip_allow.list; RTP 10000-40000"
  warn "Закрыто снаружи: 5432, 5672, 8001, 9099, 9600, 9601, 8021, 6070; чужой SIP без allow — DROP"
}

# --- sshguard (SSH bruteforce → nft sets) ------------------------------------
install_sshguard() {
  [[ "${SKIP_SSHGUARD:-0}" == "1" || "${SKIP_FIREWALL:-0}" == "1" ]] && { skip "sshguard"; return; }

  do_it "sshguard (защита SSH от брутфорса)"
  apt-get install -y -qq sshguard

  local backend=""
  for p in /usr/libexec/sshguard/sshg-fw-nft-sets /usr/lib/sshguard/sshg-fw-nft-sets; do
    if [[ -x "$p" ]]; then
      backend="$p"
      break
    fi
  done
  if [[ -z "$backend" ]]; then
    warn "не найден sshg-fw-nft-sets — sshguard может не банить через nft"
  fi

  mkdir -p /etc/sshguard
  local conf=/etc/sshguard/sshguard.conf
  if [[ ! -f "$conf" ]]; then
    touch "$conf"
  fi
  # Идемпотентно выставляем BACKEND / BLOCK_TIME / THRESHOLD
  if grep -qE '^[[:space:]]*BACKEND=' "$conf" 2>/dev/null; then
    [[ -n "$backend" ]] && sed -i -E "s|^[[:space:]]*BACKEND=.*|BACKEND=\"${backend}\"|" "$conf"
  else
    [[ -n "$backend" ]] && echo "BACKEND=\"${backend}\"" >> "$conf"
  fi
  if grep -qE '^[[:space:]]*BLOCK_TIME=' "$conf" 2>/dev/null; then
    sed -i -E 's|^[[:space:]]*BLOCK_TIME=.*|BLOCK_TIME=3600|' "$conf"
  else
    echo "BLOCK_TIME=3600" >> "$conf"
  fi
  if grep -qE '^[[:space:]]*THRESHOLD=' "$conf" 2>/dev/null; then
    sed -i -E 's|^[[:space:]]*THRESHOLD=.*|THRESHOLD=40|' "$conf"
  else
    echo "THRESHOLD=40" >> "$conf"
  fi
  # читать auth из journald (sshd)
  if ! grep -qE '^[[:space:]]*LOGREADER=' "$conf" 2>/dev/null; then
    echo 'LOGREADER="LANG=C /bin/journalctl -afb -n0 SYSTEMD_UNIT=ssh.service + SYSTEMD_UNIT=sshd.service"' >> "$conf"
  fi

  systemctl enable sshguard >/dev/null 2>&1 || true
  # Важно: после flush ruleset nftables sshguard должен пересоздать свои tables
  systemctl restart sshguard || warn "sshguard restart failed"
  if svc_active sshguard; then
    ok "sshguard active (BLOCK_TIME=3600, nft-sets)"
  else
    warn "sshguard не active"
  fi
}

# Проверка: в opensips.cfg уже есть auth-ban (3 неверных → бан 1ч по AOR).
verify_opensips_authban() {
  local cfg="/etc/opensips/opensips.cfg"
  [[ -f "$cfg" ]] || cfg="${INSTALL_DIR}/opensips/opensips.cfg"
  [[ -f "$cfg" ]] || { warn "opensips.cfg не найден — проверку auth-ban пропуск"; return; }

  # $var(fails) >= 3 — в ERE «$» = EOL, поэтому ищем cache_add authfail + порог через escapes
  if grep -qF 'authban_$tU@$td' "$cfg" \
    && grep -qF 'authfail_$tU@$td' "$cfg" \
    && grep -qE 'fails\)[[:space:]]*>=[[:space:]]*3' "$cfg" \
    && grep -q 'cache_store("local", "authban_' "$cfg"; then
    ok "OpenSIPS REGISTER auth-ban: 3 неверных пароля/user → бан AOR на 1ч (не по IP — WebRTC за nginx)"
  else
    warn "в opensips.cfg не найдена ожидаемая защита authban (3/1h) — проверьте route[is_register]"
  fi
}

print_summary() {
  local ui_url wss_url
  if [[ -f "/etc/letsencrypt/live/${MFDC_DOMAIN}/fullchain.pem" ]] && [[ "${HTTP_ONLY}" != "1" ]]; then
    ui_url="https://${MFDC_DOMAIN}/"
    wss_url="wss://${MFDC_DOMAIN}/wss/"
  else
    ui_url="http://${MFDC_DOMAIN}/"
    wss_url="(настройте HTTPS / webrtc_wss_url)"
  fi
  cat <<EOF

========================================
 MFDC install done (idempotent)
========================================
  UI:        ${ui_url}
  WSS:       ${wss_url}
  API:       127.0.0.1:8001
  Broker:    127.0.0.1:9099
  Whisper:   http://127.0.0.1:9600   (docker mfdc-whisper)
  Topics:    http://127.0.0.1:9601   (docker mfdc-topic-classifier)
  PostgreSQL ${MFDC_PG_USER} / ${MFDC_PG_PASS}  db=${MFDC_PG_DB}
  RabbitMQ   ${MFDC_RABBIT_USER} / ${MFDC_RABBIT_PASS}
  Firewall:  nftables (SSH ${MFDC_SSH_PORTS}; SIP allow-list /etc/mfdc/sip_allow.list)
  Logs:      /var/log/mfdc/*.log  (logrotate daily, keep 10)
             /var/log/freeswitch/*.log (logrotate daily, keep 10)
             /var/log/opensips.log (rsyslog local0, keep 10)
  Settings:  system.platform_settings + directory.domains (${MFDC_DOMAIN})
             api.key / jwt_secret сгенерированы если были пусты
             bin/UI: рестарт mfdc-* только при отличии от ${OPT_MFDC} / ${UI_WWW}
             recordings=${RECORDINGS_DIR}
             sounds(IVR)=${SOUNDS_DIR}  playback=${PLAYBACK_URL_BASE}
  SIP auth:  OpenSIPS 3 fails → ban AOR 1h (route[is_register])
  SIP reload: /opt/mfdc/reload-sip-allow.sh

  DNS: A/AAAA ${MFDC_DOMAIN} → этот сервер (нужно до Let's Encrypt, если выпускаете новый).
  UI → Система → Транскрипция: URL whisper/topic как выше.

  Запущены: postgresql rabbitmq freeswitch rtpengine nginx mfdc-runner/api/broker/caller/sniffer + Docker/ML.
  OpenSIPS не стартуем (нет транков/номеров). После настройки:
    systemctl enable --now opensips
  FORCE_RESTART=1  — то же + OpenSIPS
    или: systemctl start postgresql rabbitmq-server mfdc-runner nginx freeswitch mfdc-api mfdc-broker

  FORCE_CONFIG=1  — перезаписать конфиги + nftables + LE
  bash install.sh -update  — bin/UI при отличии: бэкап → ${OPT_MFDC}/backup/ + рестарт
  bash install.sh -update-rollback — восстановить из backup/previous
  SIP_ALLOW=1.2.3.4,5.6.7.0/24  — без интерактива
  HTTP_ONLY=1 / SKIP_LE=1 — без TLS
  LE_ISSUE=0 — TLS из install/cert/fullchain1.pem + privkey1.pem (без certbot)
  LE_ISSUE=1 — сразу выпустить новый Let's Encrypt
  SKIP_DOCKER=1 / SKIP_ML=1 / SKIP_FIREWALL=1 / SKIP_SSHGUARD=1

  Логи: journalctl -u mfdc-api -u mfdc-broker -u opensips -u sshguard -f
        docker ps; docker logs mfdc-whisper
        nft list set inet filter sip_allow4
========================================
EOF
}

# ── mod_audio_stream: реалтайм-форк аудио на WebSocket (docs/audio_fork_plan.md) ──────────────────
#
# Отдельная опция, а не шаг полной установки: услуга опциональная, тянет компилятор и ~2 минуты
# сборки, и нужна далеко не каждой инсталляции. Ставится на УЖЕ РАЗВЁРНУТУЮ систему и идемпотентна —
# повторный запуск пересобирает модуль (это же и способ пережить апгрейд FreeSWITCH).
#
# Работает только с ЛОКАЛЬНОЙ нодой FreeSWITCH: модуль — это .so на конкретном хосте, при нескольких
# FS-нодах команду надо выполнить на каждой (о чём функция и предупреждает).

audio_fork_require_freeswitch() {
  if command -v fs_cli >/dev/null 2>&1 || [[ -d /usr/lib/freeswitch/mod ]] || [[ -d /etc/freeswitch ]]; then
    return 0
  fi
  die "audio-fork: на этом хосте нет FreeSWITCH — модуль ставится на FS-ноду"
}

audio_fork_deps() {
  local pkgs=(git build-essential cmake pkg-config
              libfreeswitch-dev libssl-dev zlib1g-dev libevent-dev libspeexdsp-dev)
  local missing=() p
  for p in "${pkgs[@]}"; do
    pkg_installed "$p" || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    ok "audio-fork: зависимости сборки уже стоят"
    return 0
  fi
  do_it "audio-fork: пакеты сборки — ${missing[*]}"
  apt-get update -qq || true
  # libevent-dev нет в build-mod-audio-stream.sh самого модуля, хотя его libwsc построен на libevent:
  # список берём из README, а не из скрипта.
  apt-get install -qqy --no-install-recommends "${missing[@]}" \
    || die "audio-fork: не удалось поставить зависимости сборки"
}

audio_fork_fetch() {
  local src="$MFDC_AUDIO_STREAM_SRC"
  if [[ -d "$src/.git" ]]; then
    do_it "audio-fork: обновляю исходники в ${src}"
    git -C "$src" fetch --quiet --tags origin || warn "audio-fork: fetch не удался — собираю то, что есть"
    if [[ -n "$MFDC_AUDIO_STREAM_REF" ]]; then
      git -C "$src" checkout --quiet "$MFDC_AUDIO_STREAM_REF" \
        || die "audio-fork: нет ссылки ${MFDC_AUDIO_STREAM_REF} в репозитории"
    else
      # Предыдущий запуск мог закрепить версию через MFDC_AUDIO_STREAM_REF и оставить detached HEAD —
      # на нём `pull --ff-only` не работает, и запуск без REF молча собирал бы старый коммит.
      if ! git -C "$src" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
        local def
        def="$(git -C "$src" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
        [[ -n "$def" ]] || def=master
        warn "audio-fork: исходники были закреплены на версии — возвращаю на ${def}"
        git -C "$src" checkout --quiet "$def" || warn "audio-fork: не удалось вернуться на ${def}"
      fi
      git -C "$src" pull --quiet --ff-only || warn "audio-fork: pull не удался — собираю текущее состояние"
    fi
  else
    # Каталог может существовать и не быть репозиторием (оборванная ручная попытка): git clone на
    # непустой каталог откажется, а дальнейшие шаги молча соберут не то. Поэтому сносим.
    if [[ -e "$src" ]]; then
      warn "audio-fork: ${src} есть, но это не git-репозиторий — пересоздаю"
      rm -rf "$src"
    fi
    do_it "audio-fork: клонирую ${MFDC_AUDIO_STREAM_REPO} → ${src}"
    git clone --quiet --recurse-submodules "$MFDC_AUDIO_STREAM_REPO" "$src" \
      || die "audio-fork: не удалось склонировать исходники"
    if [[ -n "$MFDC_AUDIO_STREAM_REF" ]]; then
      git -C "$src" checkout --quiet "$MFDC_AUDIO_STREAM_REF" \
        || die "audio-fork: нет ссылки ${MFDC_AUDIO_STREAM_REF} в репозитории"
    fi
  fi
  # Подмодуль libwsc — это и есть websocket-клиент; без него сборки нет.
  git -C "$src" submodule update --init --recursive --quiet \
    || die "audio-fork: не удалось получить подмодуль libwsc"
  [[ -f "$src/CMakeLists.txt" ]] || die "audio-fork: в ${src} нет CMakeLists.txt — исходники неполные"
}

audio_fork_build() {
  local src="$MFDC_AUDIO_STREAM_SRC"
  do_it "audio-fork: сборка mod_audio_stream (TLS=ON)"
  rm -rf "$src/build"
  mkdir -p "$src/build"
  # USE_TLS=ON обязателен: по умолчанию TLS выключен, и адрес wss:// сохранился бы в настройках,
  # а поток бы не пошёл — снаружи это неотличимо от «настройка не работает».
  ( cd "$src/build" && cmake -DCMAKE_BUILD_TYPE=Release -DUSE_TLS=ON .. >/dev/null ) \
    || die "audio-fork: cmake не отработал (нет libfreeswitch-dev?)"
  ( cd "$src/build" && make -j"$(nproc)" >/dev/null ) \
    || die "audio-fork: сборка не удалась"
  ( cd "$src/build" && make install >/dev/null ) \
    || die "audio-fork: make install не удался"
  local moddir
  moddir="$(pkg-config --variable=modulesdir freeswitch 2>/dev/null || true)"
  [[ -n "$moddir" ]] || moddir="/usr/lib/freeswitch/mod"
  [[ -f "${moddir}/mod_audio_stream.so" ]] \
    || die "audio-fork: ${moddir}/mod_audio_stream.so не появился после установки"
  # Недостающая динамическая зависимость проявляется только при загрузке, и в fs_cli это выглядит
  # как «+OK, но модуля нет» — проверяем сразу, пока причина видна.
  local missing_libs
  missing_libs="$(ldd "${moddir}/mod_audio_stream.so" 2>/dev/null | grep 'not found' || true)"
  if [[ -n "$missing_libs" ]]; then
    warn "audio-fork: модулю не хватает библиотек:"
    echo "$missing_libs" | sed 's/^/      /'
  fi
  ok "audio-fork: модуль установлен в ${moddir}"
}

# Строка загрузки — в РАЗВЁРНУТЫЙ конфиг: репозиторный configuration.xml копируется только при первой
# установке (.mfdc-installed), поэтому на живом сервере правка нужна здесь.
audio_fork_enable_module() {
  local conf="/etc/freeswitch/configuration.xml"
  if [[ ! -f "$conf" ]]; then
    warn "audio-fork: ${conf} нет на этом хосте — добавьте <load module=\"mod_audio_stream\"/> вручную"
    return 0
  fi
  # Именно активная строка: закомментированный <!-- <load module="mod_audio_stream"/> --> тоже
  # содержит это имя, и простой grep посчитал бы модуль включённым.
  if grep -qE '^[[:space:]]*<load[[:space:]]+module="mod_audio_stream"' "$conf"; then
    ok "audio-fork: модуль уже в списке загрузки"
    return 0
  fi
  if grep -q 'module="mod_audio_stream"' "$conf"; then
    warn "audio-fork: строка загрузки есть, но закомментирована — добавляю активную"
  fi
  do_it "audio-fork: добавляю <load module=\"mod_audio_stream\"/> в ${conf}"
  # Вставка перед </modules> ВНУТРИ секции modules.conf. Ни якорь по соседнему модулю (зависит от
  # отступов развёрнутого конфига и молча промахивается), ни «первый </modules> в файле» (в
  # объединённом configuration.xml секций с таким тегом может быть несколько) не годятся.
  awk '
    /<configuration name="modules.conf"/ { inm = 1 }
    inm && !ins && /<\/modules>/ { print "    <load module=\"mod_audio_stream\"/>"; ins = 1 }
    inm && /<\/configuration>/ { inm = 0 }
    { print }
  ' "$conf" > "${conf}.mfdc-af" || { warn "audio-fork: не удалось подготовить конфиг — строка не добавлена"; rm -f "${conf}.mfdc-af"; return 0; }

  if ! grep -qE '^[[:space:]]*<load[[:space:]]+module="mod_audio_stream"' "${conf}.mfdc-af"; then
    warn "audio-fork: в ${conf} не нашлось секции modules.conf — добавьте строку загрузки вручную"
    rm -f "${conf}.mfdc-af"
    return 0
  fi
  cp -p "$conf" "${conf}.mfdc-bak" 2>/dev/null || true
  if ! mv "${conf}.mfdc-af" "$conf"; then
    warn "audio-fork: не удалось заменить ${conf} — строка не добавлена"
    rm -f "${conf}.mfdc-af"
    return 0
  fi
  chown freeswitch:freeswitch "$conf" 2>/dev/null || true
  ok "audio-fork: строка загрузки добавлена (бэкап — ${conf}.mfdc-bak)"
}

# Подписка на CUSTOM-события mod_audio_stream: единственный точный сигнал «поток форка поднялся /
# не поднялся» для конкретного звонка (диагностика в логе брокера).
#
# ОПАСНЫЙ ПОРЯДОК: у брокера без обработчика этих событий они дойдут до ProcessChannelEvent и
# запишутся в staging и в журнал звонков. Поэтому подписка добавляется, только если в развёрнутом
# бинарнике mfdc-broker есть его константа — иначе шаг пропускается с подсказкой обновить брокер.
audio_fork_enable_events() {
  local conf="/etc/freeswitch/configuration.xml" broker="${OPT_MFDC}/mfdc-broker"
  local marker="mod_audio_stream::error"

  if [[ ! -f "$conf" ]]; then
    warn "audio-fork: ${conf} нет на этом хосте — подписку на события модуля добавьте вручную"
    return 0
  fi
  # Проверяем ИМЕННО строку с канальными событиями: рядом лежит закомментированный пример, где тоже
  # есть слово SWITCH_EVENT_CUSTOM, и файловый grep дал бы ложное «уже настроено».
  if awk '/event_filter/ && /SWITCH_EVENT_CHANNEL_CREATE/ && /SWITCH_EVENT_CUSTOM/ { found = 1 }
          END { exit !found }' "$conf"; then
    ok "audio-fork: подписка на события модуля уже настроена"
    return 0
  fi
  # Строка-константа обработчика компилируется в бинарник; её отсутствие = брокер старый.
  if [[ ! -f "$broker" ]] || ! grep -qa "$marker" "$broker"; then
    warn "audio-fork: mfdc-broker без обработчика событий модуля — подписка НЕ добавлена"
    warn "audio-fork: обновите бинарники (install.sh -update) и повторите -audio-fork-install"
    return 0
  fi

  do_it "audio-fork: добавляю подписку на события mod_audio_stream в ${conf}"
  # Правим ту строку event_filter, где перечислены канальные события (у соседнего закомментированного
  # примера другое значение, слепой sed по имени параметра попал бы в него).
  #
  # Подписка широкая — SWITCH_EVENT_CUSTOM без подкласса. Подкласс здесь указывать нельзя: mod_amqp
  # резолвит строку целиком и на "SWITCH_EVENT_CUSTOM::подкласс" пишет CRIT, а отвергнутая запись всё
  # равно оседает подпиской на весь класс (CUSTOM = 0 в перечислении), то есть каждая такая запись
  # добавляет лишнюю копию каждого события. Первый проход сносит их, если их успели прописать.
  awk '
    !done && /event_filter/ && /SWITCH_EVENT_CHANNEL_CREATE/ {
      gsub(/,SWITCH_EVENT_CUSTOM::[A-Za-z0-9_:]+/, "")
      sub(/SWITCH_EVENT_BACKGROUND_JOB/, "SWITCH_EVENT_BACKGROUND_JOB,SWITCH_EVENT_CUSTOM")
      done = 1
    }
    { print }
  ' "$conf" > "${conf}.mfdc-afe" || { warn "audio-fork: не удалось подготовить конфиг — подписка не добавлена"; rm -f "${conf}.mfdc-afe"; return 0; }

  if ! awk '/event_filter/ && /SWITCH_EVENT_CHANNEL_CREATE/ && /SWITCH_EVENT_CUSTOM/ { found = 1 }
            END { exit !found }' "${conf}.mfdc-afe"; then
    warn "audio-fork: в ${conf} не нашлось event_filter с канальными событиями — добавьте подписку вручную"
    rm -f "${conf}.mfdc-afe"
    return 0
  fi
  cp -p "$conf" "${conf}.mfdc-bak" 2>/dev/null || true
  if ! mv "${conf}.mfdc-afe" "$conf"; then
    warn "audio-fork: не удалось заменить ${conf} — подписка не добавлена"
    rm -f "${conf}.mfdc-afe"
    return 0
  fi
  chown freeswitch:freeswitch "$conf" 2>/dev/null || true
  ok "audio-fork: подписка на события модуля добавлена"

  # mod_amqp читает свой профиль при загрузке модуля: одного reloadxml мало.
  if svc_active freeswitch; then
    fs_cli -x "reloadxml" >/dev/null 2>&1 || true
    fs_cli -x "reload mod_amqp" >/dev/null 2>&1 || true
    if grep -i "not recognised\|not recognized" /var/log/freeswitch/core.log 2>/dev/null |
       grep -q "^$(date +%Y-%m-%d).*SWITCH_EVENT_CUSTOM"; then
      warn "audio-fork: mod_amqp не принял SWITCH_EVENT_CUSTOM — события модуля не придут, см. core.log"
    fi
  fi
}

audio_fork_load_and_verify() {
  if ! svc_active freeswitch; then
    warn "audio-fork: FreeSWITCH не запущен — модуль подхватится при следующем старте"
    return 0
  fi
  # Если модуль уже загружен, `load` НЕ подхватит только что пересобранный .so — нужен reload.
  # Это и есть повторный запуск после апгрейда FreeSWITCH: без reload в памяти остался бы старый код.
  if fs_cli -x "show modules" 2>/dev/null | grep -q 'uuid_audio_stream'; then
    warn "audio-fork: модуль уже загружен — reload (текущие потоки форка оборвутся, звонки не пострадают)"
    fs_cli -x "reload mod_audio_stream" >/dev/null 2>&1 || true
  else
    fs_cli -x "load mod_audio_stream" >/dev/null 2>&1 || true
  fi
  # Проверять через show modules, а не show api: у свежезагруженного модуля api может не показаться,
  # и это выглядит как «не загрузился», хотя всё в порядке.
  if fs_cli -x "show modules" 2>/dev/null | grep -q 'uuid_audio_stream'; then
    ok "audio-fork: uuid_audio_stream зарегистрирован в FreeSWITCH"
  else
    warn "audio-fork: uuid_audio_stream не виден в show modules — смотрите /var/log/freeswitch/core.log"
  fi
}

install_audio_fork_module() {
  need_root
  log "mod_audio_stream (реалтайм-форк аудио)"
  audio_fork_require_freeswitch
  audio_fork_deps
  audio_fork_fetch
  audio_fork_build
  audio_fork_enable_module
  audio_fork_enable_events
  audio_fork_load_and_verify

  local nodes
  nodes="$(psql_mfdc -tAc "SELECT COUNT(*) FROM system.fs_nodes WHERE enabled" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$nodes" ]] && (( nodes > 1 )); then
    warn "audio-fork: FS-нод ${nodes} — команду нужно выполнить на КАЖДОЙ (модуль это .so на хосте)"
  fi
  echo
  echo "  Дальше: Настройки → Форк аудио (адрес ws://…), затем тумблер у нужных внутренних номеров."
  echo "  Диагностика при debug_mode: journalctl -u mfdc-broker -f | grep -i audio.fork"
}

main() {
  parse_args "$@"
  if (( MFDC_AUDIO_FORK_MODE )); then
    install_audio_fork_module
    return
  fi
  if (( MFDC_UPDATE_MODE )); then
    update_mfdc_apps
    return
  fi
  if (( MFDC_ROLLBACK_MODE )); then
    rollback_mfdc_apps
    return
  fi

  need_root
  require_amd64
  require_bookworm
  prompt_public_domain
  print_plan
  require_prebuilt_artifacts

  MFDC_DEFER_START=1
  prevent_apt_starts
  trap restore_apt_starts EXIT
  stop_install_stack

  apt_base
  ensure_hostname_loopback

  install_freeswitch
  install_postgres
  install_opensips
  install_rabbitmq
  install_rtpengine

  deploy_freeswitch_conf
  # mod_audio_stream ставится вместе со стеком: репозиторный configuration.xml уже содержит строку
  # его загрузки, и без .so на ноде FreeSWITCH писал бы про ненайденный модуль на каждом старте.
  # Сборка идёт в подоболочке: это опциональная услуга, и её падение (нет libfreeswitch-dev, нет
  # сети за git) не имеет права прерывать установку платформы.
  if ! ( install_audio_fork_module ); then
    warn "audio-fork: модуль не собрался — платформа ставится без реалтайм-форка (позже: bash install.sh -audio-fork-install)"
  fi
  deploy_opensips_conf
  verify_opensips_authban
  deploy_mfdc

  install_docker
  install_firewall
  install_sshguard
  # ML после nft: иначе flush ruleset сносит DOCKER-chains, пока образ ещё собирается.
  install_ml

  stop_install_stack
  start_install_stack
  print_summary
}

main "$@"
