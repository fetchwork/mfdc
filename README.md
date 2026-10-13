# MFDC

АТС и контакт-центр: FreeSWITCH, OpenSIPS, PostgreSQL, RabbitMQ, веб-панель.

Готовый пакет для Debian 12 (bookworm) amd64. На сервере ничего не собирается из исходников — ставятся пакеты и файлы из этого репозитория.

Без файла лицензии платформа работает в демо. Коммерческая лицензия снимает ограничения: [Telegram @voip_dmitiy](https://t.me/voip_dmitiy).

## Демо

Файл лицензии не нужен. Пока лицензия не установлена, на домен действуют пределы:

- до **10** SIP-устройств;
- до **5** операторов контакт-центра.

Остальной функционал доступен. Просроченная или неверная лицензия работу останавливает; отсутствие лицензии — нет.

## Лицензия

1. Установите платформу и откройте в панели раздел **Лицензии**.
2. Скачайте запрос и отправьте его в Telegram: [t.me/voip_dmitiy](https://t.me/voip_dmitiy).
3. Полученный `licence.json` загрузите на той же странице.

Публичный ключ проверки уже в пакете (`public.key`) и записывается в базу при установке.

## Установка

Нужны root, Debian 12 amd64 и DNS A-запись домена на этот сервер. Для пакетов FreeSWITCH нужен персональный токен SignalWire (`TOKEN`).

```bash
git clone https://github.com/fetchwork/mfdc.git
cd mfdc
unzip -o ui.zip -d ui
export TOKEN='xxxxxxxx'
# необязательно, иначе скрипт спросит:
# export MFDC_DOMAIN=pbx.example.com LE_EMAIL=admin@example.com
bash install.sh
```

Скрипт спросит домен и email для Let's Encrypt, затем поставит FreeSWITCH, PostgreSQL, OpenSIPS, RabbitMQ, rtpengine, nginx, панель и сервисы `mfdc-*`.

Пароль PostgreSQL по умолчанию — `mfdc_passwd` (роль `mfdc_admin`, база `mfdc`). На своей установке задайте другой через `MFDC_PG_PASS` до первого запуска.

SIP с интернета принимается только с адресов провайдеров и офиса. Список — `nftables/sip_allow.list` или вопрос при установке (`SIP_ALLOW=203.0.113.10,198.51.100.0/24`).

Лаборатория без TLS: `HTTP_ONLY=1`.

## Обновление

```bash
cd /path/to/mfdc
git pull
unzip -o ui.zip -d ui
bash install.sh -update
```

`-update` копирует бинарники в `/opt/mfdc` и интерфейс в `/var/www/mfdc-ui`, предыдущую копию кладёт в `/opt/mfdc/backup` и перезапускает только то, что изменилось.

Откат:

```bash
bash install.sh -update-rollback
```

## После установки

```bash
systemctl status mfdc-runner mfdc-api mfdc-broker opensips freeswitch rabbitmq-server
```

Панель: `https://ваш-домен/`. Дальше — внутренние номера, транки, схемы.

Полезные переменные: `SKIP_DOCKER=1`, `SKIP_ML=1`, `SKIP_FIREWALL=1`, `FORCE_CONFIG=1`. Полный список — в шапке `install.sh`.
