#!/usr/bin/env bash
# movrec.sh — разложить записи разговоров (плоские файлы, в т.ч. привезённые с другого сервера)
# по структуре платформы:
#   <корень записей>/<domain_id>/ГГГГ/ММ/ДД/<файл>
# и обновить пути в broker.cdr.record_file.
#
# Обновление БД обязательно: путь хранится полным, по нему играет журнал CDR и резолвятся
# разосланные CRM-ссылки. Для перенесённой с другого сервера базы старый префикс каталога
# неизвестен, поэтому сопоставление идёт ПО ИМЕНИ ФАЙЛА: одна временная таблица
# «имя → новая папка» и один UPDATE-join (один проход по broker.cdr на всю пачку,
# а не seq scan на каждый файл).
#
# Дата берётся из имени файла (2026-08-19-15-18-49_<uuid>.mp3 — момент создания записи),
# при нераспознаваемом имени — из mtime (tar их сохраняет).
#
# ВАЖНО: <корень записей> обязан совпадать с «Каталог записей» в Настройки → Медиа —
# плеер отдаёт только файлы ПОД этим каталогом (иначе 403 invalid recording path).
#
# Использование:
#   ./movrec.sh <src_dir> <domain_id> <recordings_root> [db]        # dry-run (ничего не меняет)
#   ./movrec.sh --apply <src_dir> <domain_id> <recordings_root> [db]
# Пример (архив со старого сервера распакован в /tmp/mfdc):
#   ./movrec.sh --apply /tmp/mfdc 5 /var/lib/freeswitch/recordings mfdc
set -euo pipefail
export LC_ALL=C

APPLY=0
if [ "${1:-}" = "--apply" ]; then
  APPLY=1
  shift
fi
SRC="${1:-}"
DOMAIN="${2:-}"
ROOT="${3:-}"
DB="${4:-mfdc}"

usage() {
  echo "Использование: $0 [--apply] <src_dir> <domain_id> <recordings_root> [db]" >&2
  echo "Пример:        $0 --apply /tmp/mfdc 5 /var/lib/freeswitch/recordings mfdc" >&2
  exit 1
}
[ -n "$SRC" ] && [ -n "$DOMAIN" ] && [ -n "$ROOT" ] || usage
case "$DOMAIN" in ''|*[!0-9]*) echo "ERROR: domain_id должен быть числом: '$DOMAIN'" >&2; exit 1 ;; esac
SRC="${SRC%/}"; ROOT="${ROOT%/}"
[ -d "$SRC" ] || { echo "ERROR: каталог-источник не найден: $SRC" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "ERROR: корень записей не найден: $ROOT" >&2; exit 1; }
# Абсолютные пути обязательны: они уходят в broker.cdr.record_file как есть.
SRC="$(cd "$SRC" && pwd)"
ROOT="$(cd "$ROOT" && pwd)"
command -v psql >/dev/null 2>&1 || { echo "ERROR: psql не найден — без обновления broker.cdr раскладывать нельзя" >&2; exit 1; }

ROOT_OWNER="$(stat -c %U "$ROOT")"
ROOT_GROUP="$(stat -c %G "$ROOT")"
DEST_BASE="$ROOT/$DOMAIN"

SQL_FILE="$(mktemp /tmp/movrec-XXXXXX.sql)"
# mktemp даёт 0600 root'а, а psql под `sudo -u postgres` читает файл уже от postgres —
# без chmod применение падало с Permission denied (файлы к тому моменту уже перенесены).
chmod 644 "$SQL_FILE"
cat > "$SQL_FILE" <<'SQLHEAD'
BEGIN;
CREATE TEMP TABLE movrec_map (stem text PRIMARY KEY, dest text NOT NULL);
SQLHEAD

NOW="$(date +%s)"
moved=0
skipped_fresh=0
skipped_unsafe=0
skipped_exists=0

# Свежие файлы (моложе 10 минут) не трогаем: если источник — живой каталог записей,
# такой файл может дописывать FreeSWITCH прямо сейчас. Для архива guard не срабатывает.
FRESH_SEC=600

# Файлы ищутся рекурсивно (архив мог сохранить подпапки), целевое дерево исключается —
# так скрипт безопасен и когда src совпадает с корнем записей (раскладка на месте).
while IFS= read -r -d '' f; do
  base="$(basename "$f")"

  # Имя обязано быть безопасным для SQL-литерала (у записей платформы это так:
  # дата + uuid). Всё прочее пропускаем с предупреждением.
  case "$base" in
    *"'"*|*'\'*)
      echo "SKIP (небезопасное имя): $base" >&2
      skipped_unsafe=$((skipped_unsafe + 1))
      continue ;;
  esac

  mtime="$(stat -c %Y "$f")"
  if [ $((NOW - mtime)) -lt "$FRESH_SEC" ]; then
    echo "SKIP (моложе 10 мин, может писаться сейчас): $base"
    skipped_fresh=$((skipped_fresh + 1))
    continue
  fi

  # Дата: из имени ГГГГ-ММ-ДД-... , иначе из mtime.
  if [[ "$base" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})- ]]; then
    Y="${BASH_REMATCH[1]}"; M="${BASH_REMATCH[2]}"; D="${BASH_REMATCH[3]}"
  else
    Y="$(date -d "@$mtime" +%Y)"; M="$(date -d "@$mtime" +%m)"; D="$(date -d "@$mtime" +%d)"
  fi

  dest_dir="$DEST_BASE/$Y/$M/$D"
  if [ -e "$dest_dir/$base" ]; then
    echo "SKIP (уже существует в назначении): $dest_dir/$base" >&2
    skipped_exists=$((skipped_exists + 1))
    continue
  fi

  stem="${base%.*}"
  echo "MOVE $base -> $DOMAIN/$Y/$M/$D/"
  # Пара .wav/.mp3 даёт один stem и одну строку карты — ON CONFLICT схлопывает дубль.
  printf "INSERT INTO movrec_map VALUES ('%s', '%s') ON CONFLICT (stem) DO NOTHING;\n" "$stem" "$dest_dir" >> "$SQL_FILE"

  if [ "$APPLY" = "1" ]; then
    if [ ! -d "$dest_dir" ]; then
      # Права как у mfdc-runner: setgid + group-write, владелец/группа корня записей —
      # чтобы FreeSWITCH мог дописывать в эти же папки новые файлы, а runner — читать.
      mkdir -p "$dest_dir"
      for part in "$DEST_BASE" "$DEST_BASE/$Y" "$DEST_BASE/$Y/$M" "$dest_dir"; do
        chown "$ROOT_OWNER:$ROOT_GROUP" "$part" 2>/dev/null || true
        chmod 2775 "$part"
      done
    fi
    mv -n "$f" "$dest_dir/"
    chown "$ROOT_OWNER:$ROOT_GROUP" "$dest_dir/$base" 2>/dev/null || true
    chmod 0664 "$dest_dir/$base"
  fi
  moved=$((moved + 1))
done < <(find "$SRC" \( -path "$DEST_BASE" -prune \) -o -type f \( -name '*.wav' -o -name '*.mp3' \) -print0)

# Один проход по broker.cdr: строка подходит, если её basename без расширения есть в карте.
# Старый префикс каталога (путь со старого сервера) при этом не важен. S3-ссылки не трогаем.
cat >> "$SQL_FILE" <<'SQLTAIL'
UPDATE broker.cdr c
   SET record_file = m.dest || '/' || regexp_replace(c.record_file, '^.*/', ''),
       updated_at = now()
  FROM movrec_map m
 WHERE COALESCE(c.record_file, '') <> ''
   AND c.record_file NOT LIKE 's3:%'
   AND regexp_replace(regexp_replace(c.record_file, '^.*/', ''), '\.(wav|mp3)$', '') = m.stem
   AND c.record_file <> m.dest || '/' || regexp_replace(c.record_file, '^.*/', '');
COMMIT;
SQLTAIL

echo ""
echo "Итого: к переносу $moved, пропущено: свежих $skipped_fresh, небезопасных $skipped_unsafe, дубликатов $skipped_exists"

if [ "$APPLY" != "1" ]; then
  echo "DRY-RUN: ничего не изменено. SQL-план: $SQL_FILE"
  echo "Запустите с --apply для выполнения."
  exit 0
fi

if [ "$moved" = "0" ]; then
  rm -f "$SQL_FILE"
  echo "Переносить нечего."
  exit 0
fi

# Файлы уже перенесены — обновление БД обязано пройти. При сбое SQL-файл сохраняется,
# чтобы обновление можно было повторить вручную: до этого журнал/CRM не найдут записи.
if sudo -u postgres psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$SQL_FILE"; then
  rm -f "$SQL_FILE"
  echo "Готово: $moved файлов перенесено, пути в broker.cdr обновлены."
else
  echo "ERROR: обновление broker.cdr НЕ прошло. Файлы уже перенесены — примените SQL вручную:" >&2
  echo "  sudo -u postgres psql -v ON_ERROR_STOP=1 -d $DB -f $SQL_FILE" >&2
  exit 1
fi
