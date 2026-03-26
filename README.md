<div align="center">

# 🛠️ server-manager

> Модульный инструмент управления VPN-инфраструктурой.  
> Написан на Go. Один статический бинарник без зависимостей.

```bash
# Установка
curl -fsSL https://github.com/stump3/server-manager/releases/latest/download/server-manager-linux-amd64 \
  -o /usr/local/bin/server-manager && chmod +x /usr/local/bin/server-manager

# Запуск (интерактивное TUI-меню)
server-manager
```

[![Go](https://img.shields.io/badge/Go-1.23-00ADD8?style=flat-square&logo=go)](https://go.dev)
[![License](https://img.shields.io/badge/license-MIT-22c55e?style=flat-square)](LICENSE)
[![Changelog](https://img.shields.io/badge/changelog-CHANGELOG.md-f59e0b?style=flat-square)](CHANGELOG.md)

</div>

---

## Компоненты

| Компонент | Описание |
|---|---|
| 🛡️ **Remnawave Panel** | VPN-панель (Xray/Reality selfsteal, cookie-защита, wildcard SSL) |
| 📡 **MTProxy (telemt)** | Telegram MTProto прокси на Rust, systemd или Docker |
| 🚀 **Hysteria2** | Высокоскоростной VPN поверх QUIC/UDP |

---

## Использование

### Интерактивное TUI (по умолчанию)

```
server-manager
```

Запускает полноэкранное меню с живым статусом всех сервисов, автообновлением каждые 10 сек.

### CLI (для скриптов и CI)

```bash
# Статус всех сервисов
server-manager status

# Управление панелью
server-manager panel status
server-manager panel restart [all|nginx|panel|sub|node]
server-manager panel update
server-manager panel logs --lines 100 --container nginx
server-manager panel remove

# Hysteria2
server-manager hysteria restart
server-manager hysteria logs --lines 60
server-manager hysteria users
server-manager hysteria add-user --username alice
server-manager hysteria add-user --username bob --password mysecret
server-manager hysteria del-user --username bob

# MTProxy
server-manager telemt restart
server-manager telemt update
server-manager telemt links
server-manager telemt users

# Миграция на другой сервер
server-manager migrate --to 1.2.3.4 --key ~/.ssh/id_ed25519 --all
server-manager migrate --to 1.2.3.4 --password mypass --panel --hysteria
server-manager migrate --to 1.2.3.4 --all --stop-source
```

### Флаги

| Флаг | Описание |
|---|---|
| `--config path` | Путь к конфиг-файлу (по умолчанию `~/.config/server-manager/config.yaml`) |

---

## Установка и сборка

### Готовый бинарник (рекомендуется)

```bash
VERSION=latest
curl -fsSL "https://github.com/stump3/server-manager/releases/${VERSION}/download/server-manager-linux-amd64" \
  -o /usr/local/bin/server-manager
chmod +x /usr/local/bin/server-manager
```

### Сборка из исходников

```bash
git clone https://github.com/stump3/server-manager
cd server-manager
make build-linux          # → dist/server-manager-linux-amd64
make install              # копирует в /usr/local/bin/server-manager
```

Требования: Go 1.23+. CGO не нужен.

---

## Конфигурация

Создайте `~/.config/server-manager/config.yaml` (все поля опциональны):

```yaml
log_level: info   # debug | info | warn | error

ssh:
  keepalive_interval: 15   # сек, защита от TCP-таймаута при долгих операциях
  keepalive_max_count: 3
  connect_timeout: 15

panel:
  dir: /opt/remnawave
  mgmt_script: /usr/local/bin/remnawave_panel
```

Переменные окружения перекрывают файл: `SM_LOG_LEVEL=debug server-manager status`

---

## Архитектура

Проект построен по принципам **гексагональной архитектуры** (Ports & Adapters):

```
cmd/server-manager/
  └── main.go               ← точка входа: TUI или CLI

internal/
  ├── ports/                ← интерфейсы (контракты)
  │   ├── runner.go         Runner — exec команд (local / remote)
  │   ├── ssh.go            SSHClient + SSHDialer
  │   ├── fs.go             FS — атомарная запись файлов
  │   ├── clock.go          Clock — тестируемое время
  │   ├── network.go        Network — PublicIP, DNS, CheckPort
  │   ├── firewall.go       Firewall — ufw
  │   ├── systemd.go        Systemd — управление юнитами
  │   ├── certs.go          CertManager — certbot
  │   └── panel_api.go      PanelAPI — HTTP-клиент Remnawave
  │
  ├── domain/               ← чистая бизнес-логика (без I/O)
  │   ├── panel/            Panel struct + Validate()
  │   ├── hysteria/         Hysteria struct + Validate()
  │   ├── telemt/           Telemt struct + Validate()
  │   └── migrate/          Plan + Result + DNSMatchesIP()
  │
  ├── service/              ← use-cases (оркестрация через порты)
  │   ├── panel_service.go
  │   ├── hysteria_service.go
  │   ├── telemt_service.go
  │   ├── migrate_service.go
  │   └── health_service.go
  │
  ├── infra/                ← адаптеры (реализуют порты)
  │   ├── ssh/              golang.org/x/crypto/ssh + pkg/sftp + keepalive
  │   ├── runner/           os/exec + WithRetry decorator
  │   ├── fs/               atomic write (tmp → rename)
  │   ├── systemd/          systemctl через Runner
  │   ├── firewall/         ufw через Runner
  │   ├── certs/            certbot CLI
  │   ├── panelapi/         HTTP-клиент
  │   ├── network/          net + http (PublicIP, DNS, CheckPort)
  │   ├── clock/            RealClock + MockClock
  │   └── fsparser/         .env / YAML / TOML парсеры
  │
  ├── step/                 ← транзакционный план с rollback
  ├── errors/               ← типизированные sentinel-ошибки
  ├── templates/            ← embed.FS шаблоны (panel, hysteria, telemt)
  ├── config/               ← koanf loader (YAML + env)
  ├── observability/        ← slog + RedactHandler
  ├── tui/                  ← bubbletea: главное меню + экраны
  ├── cli/                  ← cobra субкоманды
  └── app/                  ← DI container + Bootstrap
```

### Ключевые решения

**SSH без sshpass** — нативный `golang.org/x/crypto/ssh` + SFTP. Поддержка password и key auth. TCP keepalive защищает от разрыва при долгих операциях (дамп БД).

**Атомарная запись конфигов** — `fs.Write()` делает `tmp → rename` в той же директории, что гарантирует атомарность на уровне FS. Битый конфиг при сбое питания невозможен.

**Шаблоны в бинарнике** — все конфиги (docker-compose, nginx, .env, systemd-юниты) компилируются через `//go:embed`. Один файл — полный инструмент.

**Транзакционная установка** — `step.Plan` выполняет шаги последовательно; при ошибке откатывает уже выполненные в обратном порядке (UFW, systemd, файлы).

**Параллельный сбор статуса** — `HealthService.Collect()` запускает три горутины одновременно. Задержка = max(panel, telemt, hysteria), не сумма.

---

## Тестирование

```bash
# Все unit-тесты
make test

# Только короткие
make test-unit

# Контрактные тесты портов
make test-contract

# Интеграционные (реальные системные команды)
make test-integration

# E2E (требует реальный сервер)
SM_E2E_HOST=1.2.3.4 SM_E2E_KEY=~/.ssh/id_ed25519 make test-e2e
```

Покрытие тестами: unit-тесты для каждого слоя, контрактные тесты для `Runner` и `FS` (любая реализация должна пройти тот же набор), mock-адаптеры для всех портов.

---

## Миграция с bash-версии

Если вы использовали `server-manager.sh`, все данные совместимы:
- `/opt/remnawave/` — без изменений
- `/etc/hysteria/config.yaml` — читается напрямую
- `/etc/telemt/telemt.toml` — читается напрямую
- SSH-миграция: те же операции, без `sshpass`

---

## Зависимости

| Библиотека | Назначение |
|---|---|
| `charmbracelet/bubbletea` | TUI фреймворк |
| `charmbracelet/lipgloss` | TUI стили |
| `spf13/cobra` | CLI команды |
| `golang.org/x/crypto/ssh` | SSH клиент |
| `pkg/sftp` | SFTP передача файлов |
| `knadh/koanf` | Конфигурация |
| `BurntSushi/toml` | TOML парсер |
| `gopkg.in/yaml.v3` | YAML парсер |
