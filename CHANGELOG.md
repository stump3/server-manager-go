# Changelog

## [4.0.0] — 2026-03-26 — Go rewrite

### 🚀 Breaking changes

- Проект переписан с bash на Go. Бинарник заменяет все `lib/*.sh`.
- Точка входа: `server-manager` (единый статический бинарник).
- Конфигурационный файл: `~/.config/server-manager/config.yaml` (опционально).

### ✨ Новое

**Архитектура**
- Гексагональная архитектура (Ports & Adapters): domain → service → infra
- `internal/step` — транзакционный план с rollback: при ошибке установки уже выполненные шаги откатываются в обратном порядке
- `internal/errors` — типизированные sentinel-ошибки (`ErrPortBusy`, `ErrDNSMismatch`, `ErrSSHAuth` и др.)
- Все конфиги компилируются в бинарник через `//go:embed`

**SSH и файловые операции**
- Нативный SSH без `sshpass` — `golang.org/x/crypto/ssh` + `pkg/sftp`
- Поддержка key-based auth и password auth
- TCP keepalive предотвращает разрыв при долгих операциях (pg_dumpall, apt-get)
- Атомарная запись файлов: `tmp → fsync → rename` — исключает битые конфиги при сбое

**Миграция**
- Дамп PostgreSQL через gzip pipe без temp-файла на сервере
- Ожидание `pg_isready` вместо фиксированного sleep
- Параллельный перенос MTProxy + Hysteria2 (Panel ждёт последней — зависимость от DB)
- Rollback при ошибке каждого компонента

**TUI (bubbletea)**
- Главное меню с живым дашбордом статусов (параллельный сбор, автообновление 10 сек)
- Мастер миграции: пошаговая форма SSH + выбор компонентов + прогресс в реальном времени
- Экраны управления Panel, Hysteria2, MTProxy

**CLI (cobra)**
- `server-manager status` — статус всех сервисов
- `server-manager panel status|restart|update|logs|remove`
- `server-manager hysteria restart|logs|users|add-user|del-user`
- `server-manager telemt restart|update|links|users`
- `server-manager migrate --to IP --all [--stop-source]`
- `--config path` — явный путь к конфиг-файлу
- Переменные окружения: `SM_LOG_LEVEL`, `SM_SSH_KEEPALIVE_INTERVAL` и др.

**Наблюдаемость**
- `slog` с авторедактированием sensitive-полей (password, token, secret, key) в логах
- `SM_DEBUG=1` → уровень debug

**Тестирование**
- 59 файлов Go, 1583 строки тестов
- Контрактные тесты для `Runner` и `FS` — любая реализация порта должна пройти
- Mock-адаптеры для всех 9 портов
- `make test-integration` — реальные системные команды (`-tags integration`)
- `make test-e2e` — полный E2E против реального сервера (`-tags e2e`)

---

## [3.1.0] — 2026-03-25

### 🔧 Исправления — hysteria.sh

- **Атомарные записи конфига Hysteria2** — три операции `sed -i` заменены на паттерн `mktemp → модификация → mv`:
  - `hysteria_delete_user()` — удаление строки через `grep -v` в tmpfile
  - `hysteria_add_user()` — вставка новой строки через `awk` в tmpfile
  - Обновление пароля — `sed` без флага `-i`, результат через tmpfile

- **Устранено двойное объявление `auth_mode` / `auth_badge`** в `hysteria_remnawave_integration()`

### 🔧 Исправления — migrate.sh

- **`sleep 20` → `pg_isready` polling** — фиксированное ожидание заменено циклом с таймаутом 60 сек

---

## [3.0.0] — 2026-03-21

### HTTP аутентификация Hysteria2

- **`auth.type: http`** — hysteria не хранит пользователей в `config.yaml`. При подключении клиента делает `POST /auth` к hy-webhook, который проверяет `users.json`. Пользователи добавляются без перезапуска hysteria.
- **Меню переключения режима auth** — Hysteria2 → Подписка → Интеграция → Режим аутентификации
- **`process_event` — фоновая обработка** — `_respond(200)` до запуска обработки
- **Debounce перезапуска** — `threading.Timer(2.0)` батчит несколько событий
- **`WEBHOOK_URL`** исправлен на `http://172.30.0.1:8766/webhook`

---

## [2.5.2] — 2026-03-21

### hy-webhook.py

- **`ThreadedHTTPServer`** — многопоточный сервер
- **Фоновый перезапуск Hysteria2** — `reload_hysteria()` в daemon-потоке
- **`X-Remnawave-Signature`** — исправлен заголовок подписи
- **HMAC-SHA256** верификация вместо plain-text
- **`LISTEN_HOST`** и **`DEBUG_LOG`** переменные окружения
