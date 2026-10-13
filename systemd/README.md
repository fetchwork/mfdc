# systemd units для MFDC

## Пользователь `freeswitch`

Все unit-файлы запускаются от **`User=freeswitch`** / **`Group=freeswitch`** — тот же пользователь, что и FreeSWITCH (записи разговоров, mod_http_cache, каталоги FS).

Требуется установленный пакет FreeSWITCH (пользователь `freeswitch` уже существует в системе).

```bash
sudo bash install/systemd/install-mfdc-runtime.sh
getent passwd freeswitch
```

## Установка

```bash
sudo bash install/systemd/install-mfdc-runtime.sh

sudo install -m 0640 settings.conf /opt/mfdc/settings.conf
sudo chown root:freeswitch /opt/mfdc/settings.conf

sudo cp install/systemd/mfdc-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now mfdc-runner
sudo systemctl enable --now mfdc-api mfdc-broker
# при необходимости:
sudo systemctl enable --now mfdc-caller
# mfdc-licence — НЕ на клиентских стендах (только у продавца лицензий)
```

**`mfdc-runner`** при старте создаёт полную структуру БД (DDL встроен в бинарник, внешние SQL-файлы не нужны).  
Для демо-стенда добавьте флаг **`-demo`**: при **каждом старте** `mfdc-runner` сразу очищает данные предыдущих тестировщиков (схемы, очереди, CDR, не-admin учётки, 2FA, refresh-сессии), затем то же повторяется каждый день в **03:00 UTC**. Не трогаются: схема `licence` (сервер продавца), загруженные ключи `public.licences`, `directory.domains`, ноды FS, `public.version` (OpenSIPS), bootstrap-admin.

`mfdc-api`, `mfdc-broker` и `mfdc-caller` стартуют **после** `mfdc-runner` (см. `After=` в unit-файлах).

Структура `/opt/mfdc`:

```
/opt/mfdc/
  settings.conf          # root:freeswitch 0640
  mfdc-api
  mfdc-broker
  mfdc-runner            # опционально
  mfdc-caller            # опционально
  licence/               # только public.key (проверка лицензий); бинарник mfdc-licence у продавца
```

`WorkingDirectory=/opt/mfdc`, бинарники в `/opt/mfdc/`.

## Один инстанс mfdc-broker

На кластер — **ровно один** `mfdc-broker`, даже при нескольких нодах FreeSWITCH (все FS шлют события в одну очередь RabbitMQ).  
Подробнее: `mfdc-broker/README.md`.

## Записи разговоров

Каталог по умолчанию: `/var/lib/freeswitch/recordings/mfdc` (`freeswitch:freeswitch`, `2775`).  
Сервисы MFDC и FreeSWITCH работают от одного пользователя — отдельная группа не нужна.

## Входящие очереди (broker ACD)

Блок схемы **Очередь** (`join_queue`) использует **broker ACD** в `mfdc-broker`, без `mod_callcenter`:

1. Dialplan: `answer` → `curl /queue/register` → `park`
2. Broker: member в PostgreSQL, dispatch операторов (`desk_state=ready`), `bgapi originate`
3. На ответе оператора: `uuid_bridge` (AMQP `CHANNEL_ANSWER`)

**Не нужно:** `mod_callcenter`, `callcenter_config queue load`, xml_curl binding `configuration` → `/configuration`.

**Ноды FS:** только через `/system/fs-nodes`. `node_id` = AMQP routing key = `amqp_consumer_key` в `vars.xml` (строку обновляет **mfdc-runner**). В RabbitMQ UI binding создаётся автоматически при старте FS (mod_amqp).

**Нужно на FS:**
- `mod_amqp` (события в RabbitMQ; в `event_filter` обязательны `CHANNEL_PARK`, `CHANNEL_BRIDGE`, `BACKGROUND_JOB`, …)
- `mod_xml_curl` только для **dialplan** → `http://127.0.0.1:9099/dialplan`
- `mod_curl` — только для HTTP-блоков схемы (не для `join_queue`)
- ESL на `8021` (broker шлёт originate/bridge/kill на `system.fs_nodes.esl_addr`)

Миграция `078_inbound_queue_broker.sql`, пересборка **mfdc-api** + **mfdc-broker**, перекомпиляция схем с `join_queue`.

Ручной sync mod_callcenter (`POST /api/system/fs-nodes/sync-callcenter`) **отключён** — endpoint возвращает `deprecated: true`.

## Миграция с пользователя `mfdc`

Если ранее использовался отдельный пользователь `mfdc`:

```bash
sudo bash install/systemd/install-mfdc-runtime.sh
sudo cp install/systemd/mfdc-*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl restart mfdc-api mfdc-broker mfdc-runner mfdc-caller
# проверка:
sudo -u freeswitch test -r /var/lib/freeswitch/recordings/mfdc && echo OK
```

Пользователь `mfdc` можно удалить, если больше не используется: `sudo userdel mfdc`.

## Управление

```bash
sudo systemctl reload mfdc-api    # SIGHUP
sudo journalctl -u mfdc-api -n 50 --no-pager
```
