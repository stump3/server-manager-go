# Architecture Guide

> Инженерная документация по внутреннему устройству server-manager (Go).

---

## Принципы проектирования

**Гексагональная архитектура** (Ports & Adapters) — бизнес-логика не зависит от инфраструктуры. `service/` вызывает только интерфейсы из `ports/`; конкретные реализации живут в `infra/`.

**Правило зависимостей:**
```
cmd → app → service → ports ← infra
                ↑
            domain (чистые модели, нет I/O)
```

`domain/` не импортирует ничего кроме `errors/`. `service/` не импортирует `infra/`.

---

## Слои

### ports/ — контракты

Девять интерфейсов. Любой слой выше `infra/` видит только эти интерфейсы.

| Интерфейс | Реализация | Назначение |
|---|---|---|
| `Runner` | `infra/runner/local_exec.go` | Exec, ExecScript (local) |
| `SSHClient` / `SSHDialer` | `infra/ssh/client.go` | Remote exec + SFTP |
| `FS` | `infra/fs/os_fs.go` | Atomic read/write/exists |
| `Clock` | `infra/clock/clock.go` | Testable time |
| `Network` | `infra/network/net_impl.go` | PublicIP, DNS, CheckPort |
| `Firewall` | `infra/firewall/ufw.go` | ufw allow/deny |
| `Systemd` | `infra/systemd/unit_manager.go` | systemctl |
| `CertManager` | `infra/certs/certbot.go` | certbot issue/renew |
| `PanelAPI` | `infra/panelapi/client.go` | HTTP Remnawave API |

`ports/clock.go` — интерфейс живёт в `ports/`, реализации в `infra/clock/`:
- `Real` — `time.Now()` и т.д.
- `Mock` — управляемые часы для тестов, `Advance(d)`, `Sleep(d)` сдвигает время

### domain/ — чистые бизнес-сущности

Никакого I/O. Только structs + `Validate() error`.

```go
// domain/panel/model.go
type Panel struct {
    InstallMode     InstallMode
    PanelDomain     string
    CertMethod      CertMethod
    DBPassword      string
    CookieKey       string
    // ...
}

func (p *Panel) Validate() error { /* проверки */ }
```

Доменные правила (не инфраструктурные):
- `domain/migrate/plan.go` — `DNSMatchesIP(resolvedIPs, targetIP)` — бизнес-правило «домен должен указывать на целевой сервер»
- `domain/migrate/plan.go` — `reorderComponents()` — Panel всегда последний (зависит от DB/Redis)

### step/ — транзакционный план

```go
plan := step.New("panel-install",
    step.Step{
        Name: "write-config",
        Do:   func(ctx context.Context) error { return writeConfig() },
        Undo: func(ctx context.Context) error { return os.Remove(configPath) },
    },
    step.Step{
        Name: "docker-up",
        Do:   func(ctx context.Context) error { return dockerUp() },
        Undo: func(ctx context.Context) error { return dockerDown() },
    },
)
if err := plan.Execute(ctx); err != nil {
    // docker-up упал → автоматически вызван Undo("write-config")
}
```

Правила rollback:
- Откат в обратном порядке завершённых шагов
- `Undo == nil` → шаг пропускается при откате
- Ошибки `Undo` логируются, но не заменяют оригинальную ошибку

### service/ — оркестрация

Каждый сервис получает зависимости через конструктор:

```go
func NewMigrateService(
    dialer  ports.SSHDialer,
    runner  ports.Runner,
    fs      ports.FS,
    sd      ports.Systemd,
    clk     ports.Clock,
) *MigrateService
```

`MigrateService.Execute()` транслирует прогресс через канал — TUI читает из него в реальном времени, CLI просто печатает.

`HealthService.Collect()` — три горутины параллельно, ждёт через unbuffered channel:
```go
results := make(chan result, 3)
go func() { results <- result{"panel", h.panelStatus(ctx)} }()
go func() { results <- result{"telemt", h.telemtStatus(ctx)} }()
go func() { results <- result{"hysteria", h.hysteriaStatus(ctx)} }()
// собирает 3 результата
```

### infra/ — адаптеры

**`infra/ssh/client.go`** — ключевые решения:

```go
// Keepalive — предотвращает TCP timeout при pg_dumpall (может идти 5-10 мин)
func (c *Client) keepalive(interval time.Duration, maxFails int) {
    ticker := time.NewTicker(interval)
    fails := 0
    for range ticker.C {
        _, _, err := c.native.SendRequest("keepalive@openssh.com", true, nil)
        if err != nil {
            fails++
            if fails >= maxFails { c.native.Close(); return }
        } else { fails = 0 }
    }
}

// PutReader — стриминг dump прямо в remote file без temp-файла
func (c *Client) PutReader(ctx context.Context, r io.Reader, remotePath string, mode uint32) error
```

**`infra/fs/os_fs.go`** — атомарная запись:
```go
func (f *OsFS) Write(ctx, path, data, mode) error {
    tmp, _ := os.CreateTemp(dir, ".tmp-*")  // в той же директории
    tmp.Write(data)
    tmp.Chmod(mode)
    tmp.Close()
    os.Rename(tmp.Name(), path)  // атомарно (same FS)
}
```

**`infra/runner/local_exec.go`** — декоратор retry:
```go
type WithRetry struct {
    Inner    ports.Runner
    Attempts int
    Delay    time.Duration
}
```

### templates/ — конфиги в бинарнике

```go
//go:embed panel/docker-compose.yml.tmpl
var PanelDockerCompose string
```

Рендеринг через `text/template`:
```go
out, err := templates.Render(templates.PanelNginxConf,
    templates.BuildPanelNginxData(panel, certMethod, cookieKey, cookieVal))
```

`BuildPanelNginxData` автоматически выбирает режим nginx:
- `InstallMode == ModePanelWithNode` → `listen unix:/dev/shm/nginx.sock ssl proxy_protocol` + `$proxy_protocol_addr`
- иначе → `listen 443 ssl` + `$remote_addr`

---

## Добавление нового сервиса

1. **Domain**: `internal/domain/myservice/model.go` — struct + `Validate()`
2. **Port** (если нужен новый адаптер): `internal/ports/myport.go`
3. **Infra**: `internal/infra/myservice/impl.go` — реализует порт
4. **Service**: `internal/service/myservice_service.go` — use-cases
5. **Wire**: `internal/app/container.go` — добавить в `Container` и `New()`
6. **CLI**: `internal/cli/root.go` — добавить cobra-команду в `Subcommands()`
7. **TUI**: `internal/tui/screens/` — экран для нового сервиса
8. **Tests**: unit-тест сервиса с mock-адаптерами; если порт — контрактный тест

---

## Контрактные тесты

Паттерн: функция принимает `ports.Runner` (или другой порт) и гоняет один набор тестов. Применяется ко всем реализациям:

```go
// test/contracts/runner_contract.go
func RunnerContract(t *testing.T, r ports.Runner) { ... }

// internal/infra/runner/local_exec_test.go
func TestLocalExec_Contract(t *testing.T) { contracts.RunnerContract(t, runner.New()) }

// test/integration/runner_integration_test.go  (-tags integration)
func TestSSHRunner_Contract(t *testing.T) { contracts.RunnerContract(t, sshRunnerForTests(t)) }
```

---

## Тестирование сервисов

Все моки реализованы вручную в `_test.go` файлах — нет фреймворка моков:

```go
type mockRunner struct {
    execFn func(ctx context.Context, cmd string, opts ...ports.RunOption) (ports.ExecResult, error)
}
func (m *mockRunner) Exec(ctx context.Context, cmd string, opts ...ports.RunOption) (ports.ExecResult, error) {
    if m.execFn != nil { return m.execFn(ctx, cmd, opts...) }
    return ports.ExecResult{Stdout: "ok"}, nil
}
```

Паттерн для тестирования сервисов:
1. Создать mock для каждого порта
2. Настроить `execFn` / `existsFn` для конкретного сценария
3. Создать сервис с моками через конструктор
4. Вызвать метод и проверить результат + side effects через `calls` slice

---

## Обработка ошибок

Все ошибки оборачиваются через `fmt.Errorf("context: %w", err)`:

```go
return fmt.Errorf("%w: SSH to %s: %v", smerr.ErrSSHConnect, addr, err)
```

Проверка в тестах:
```go
if !errors.Is(err, smerr.ErrSSHConnect) { t.Errorf("unexpected: %v", err) }
```

Чувствительные данные никогда не попадают в логи благодаря `observability.RedactHandler` — он проверяет имя поля slog по `sensitiveKeys` и заменяет значение на `[REDACTED]`.

---

## Сборка и релиз

```bash
# Локальная сборка
make build-linux          # CGO_ENABLED=0 → статический бинарник

# Все тесты
make test                 # unit + contract
make test-integration     # -tags integration (bash, без Docker)
make test-e2e             # -tags e2e (реальный сервер)

# Релиз (GitHub Actions)
# .github/workflows/release.yml собирает linux-amd64, linux-arm64
# и загружает в GitHub Releases
```
