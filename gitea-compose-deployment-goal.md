# Goal: Reproducible, self-restoring Gitea deployment for `git.svdk.dev`

**Статус:** техническое задание для AI-агента

**Цель:** реализовать рабочий Docker Compose deployment, а не только предложить архитектуру.
**Главный принцип:** *сервис не привязан к конкретному серверу; сервер можно потерять и восстановить сервис из Backblaze B2.*

## 1. Контекст и желаемый результат

Нужен личный self-hosted Git-сервер `https://git.svdk.dev` для приватных репозиториев, инфраструктурного кода, PR, Issues и CI/CD. На старте это **один VPS, один экземпляр Gitea**, без HA-кластера. Приоритет — надёжное восстановление после полной потери VPS, простота поддержки и минимальное число компонентов.

Итоговый проект должен позволять:

1. На чистом Linux-хосте развернуть **новую** Gitea с PostgreSQL через Docker Compose.
2. Настроить регулярные, консистентные и зашифрованные бэкапы **в Backblaze B2 через S3 API**.
3. На другом чистом хосте с тем же Compose-проектом **выбрать существующий snapshot** и полностью восстановить Gitea: Git-репозитории, базу, пользователей, PR, Issues, настройки, LFS, вложения и необходимые секреты.
4. Не допускать случайного создания пустого инстанса после аварии и не перезаписывать существующие данные.
5. Использовать один логический backup repository для `gitea-prod` независимо от того, находится Gitea на VPS, Samovar или другом сервере.
6. В будущем применять такой же подход к другим Compose-проектам **без написания уникального backup framework под каждый проект**.

**Критерий успеха:** можно уничтожить тестовый VPS, поднять пустую машину и восстановить Gitea только из кода deployment-проекта, доступа к B2 и заранее сохранённых секретов. Восстановление должно быть проверено реальными операциями Git и приложением, а не только статусом `restic restore`.

## 2. Зафиксированные технологические решения

| Компонент | Решение |
|---|---|
| Git-хостинг | Gitea Community Edition, стабильная версия с зафиксированным image tag/digest |
| База | Отдельный PostgreSQL-контейнер **в том же Compose-проекте** |
| Оркестрация | Docker Compose V2; **без Kubernetes и Docker Swarm** |
| HTTP / TLS | Уже существующий внешний Caddy; не запускать ещё один reverse proxy |
| Домен | `git.svdk.dev`, Gitea `ROOT_URL=https://git.svdk.dev/` |
| CI | **Gitea Actions**, не Drone; runner регистрируется отдельно |
| Registry | Встроенный Gitea Package Registry **полностью отключён**: `GITEA__packages__ENABLED=false` |
| Контейнерные образы | Внешний **GHCR** (`ghcr.io`) при необходимости публикации из CI |
| Рабочие данные | Локальный SSD, Docker volumes или явные bind mounts |
| Резервные копии | **restic** в Backblaze B2 по S3 API |
| Compose-friendly backup | Предпочтительно **Stack-back** (`lawndoc/stack-back`) после проверки совместимости и консистентности |
| Bootstrap / restore | Небольшой **повторно используемый** CLI-слой/one-shot job перед запуском Gitea |
| Terraform | **Не требуется в MVP**; возможность добавить Terraform/cloud-init позже |
| UI бэкапов | Backrest необязателен; если используется, он не должен быть необходим для аварийного восстановления |

Выбирать версии образов по официальной документации на момент реализации; **не использовать `latest` или `nightly` в production**. Не переносить пример версии Docker-образа из этого документа без проверки актуальности.

## 3. Целевая архитектура

```text
                      https://git.svdk.dev
                               |
                         Existing Caddy
                               |
                    Docker network (internal)
                               |
               +---------------+---------------+
               |                               |
          Gitea server ------------------ PostgreSQL
          Git / PR / UI                    metadata DB
          Actions server
               |
        Persistent Gitea data
               |
               +--- backup controller / Stack-back --- restic
                                                        |
                                             Backblaze B2 (S3)
                                          services/gitea-prod/restic

     Separate machine (e.g., Samovar): isolated Gitea Actions runner
     CI-built images, if needed: external ghcr.io
```

**Service identity:** `gitea-prod`, не `samovar-gitea`, `vps-1-gitea` и т. п. Hostname сохранять только в метаданных, логах и мониторинге.

Пример организации backup bucket (логическая схема; внутри каталогов restic — собственный бинарный формат):

```text
svdk-backups/
├── services/
│   ├── gitea-prod/restic/
│   ├── grafana-prod/restic/          # будущие сервисы
│   └── other-service/restic/
└── hosts/
    ├── samovar/restic/              # отдельно: системные конфиги хоста
    └── vps-main/restic/
```

Каждый сервис имеет **свой независимый restic repository**, пароль и по возможности ограниченные S3 credentials. Не требуется один общий restic repository на весь VPS.

## 4. Функциональные требования к Gitea

- Работает за Caddy по HTTPS, корректно обрабатывает `X-Forwarded-*`, clone URL и редиректы. У Gitea HTTP-порт доступен только через внутреннюю Docker-сеть либо через loopback VPS — **не открывать порт 3000 публично**.
- Git clone / fetch / push по HTTPS. SSH clone/push также желателен: отдельный правильно документированный порт, например `2222`, или существующий TCP ingress; учесть firewall и SSH URL.
- PostgreSQL изолирован в Compose network; **5432 не публикуется наружу**. Имеются healthcheck и ожидание готовности DB.
- Данные Gitea и PostgreSQL вынесены в постоянное хранилище, переживают `docker compose down` / обновление контейнеров. Никакие данные не живут только в writable layer контейнера.
- Отключена публичная регистрация пользователей по умолчанию; первый администратор создаётся безопасным воспроизводимым способом. Включить поддержку 2FA. OAuth2/OIDC Gitea можно использовать в будущем, но **не строить сейчас централизованную IAM-систему**.
- Включить Gitea Actions; обеспечить возможность защиты `main` от merge при незавершённой/неуспешной обязательной CI-проверке. Поставить пример минимального workflow для тестирования.
- **Отключить весь встроенный Package Registry**, а не только Docker-часть (`[packages] ENABLED=false`). Не выделять под packages S3 bucket и не разворачивать отдельный registry.
- CI runner не должен иметь доступ к Docker socket и секретам production VPS. Его деплой/регистрацию описать отдельно (например, Samovar в изолированной VM или другом изолированном окружении); не блокировать запуск Gitea, если runner недоступен.
- Определить разумные ограничения и retention для Actions logs/artifacts и CI cache. Не считать CI cache критичными данными.

## 5. Backup: требования к данным и целостности

Сервисный backup должен содержать **всё необходимое для восстановления работающей Gitea**, включая:

- Git-репозитории и связанные данные на диске Gitea;
- Git LFS, вложения к Issues/PR, release attachments, пользовательские аватары и другие persistent user files, если включены и находятся локально;
- **логический дамп PostgreSQL** (например, `pg_dump` custom format) и необходимые роли / параметры для restore;
- Gitea `app.ini`, криптографические ключи/секреты, связанные с работой экземпляра, и настройки приложения;
- Compose-конфигурацию / манифест версий (или независимую резервную копию исходников deployment-проекта) и metadata о версии Gitea и PostgreSQL;
- список включённых/исключённых путей и способ воспроизвести права владельцев файлов.

Не включать без необходимости:

- Docker images и build layers, скачиваемые модели, временные файлы;
- CI cache и пересоздаваемые build artifacts;
- `PGDATA` как живую файловую копию **вместо** логического дампа;
- backup staging, restic cache, временные архивы;
- Package Registry (он отключён).

**Критически важна согласованность:** нельзя считать корректным backup, состоящий из дампа PostgreSQL и копии Git-каталогов, сделанных в произвольное время при активных `git push`. Реализовать контролируемый процесс:

1. Взять lock, запрещающий параллельные backup/restore/upgrade jobs.
2. Перевести Gitea в quiesced-состояние (для простого MVP — аккуратно остановить Gitea; PostgreSQL оставить работающим).
3. Сделать логический дамп PostgreSQL и согласованную копию Gitea data. Продумать локальный staging и ограничение свободного места.
4. Вернуть Gitea в рабочее состояние **даже при ошибке бэкапа** (trap/finally).
5. Завершить и проверить содержимое staging, затем зашифровать и передать его в restic/B2; публикация успешного snapshot возможна только после завершения всех обязательных шагов.
6. Очистить staging безопасно; сохранить результат, продолжительность, объём и причину ошибки.

Первоначальную большую файловую копию можно выполнять при работающей Gitea, **но финальную синхронизацию и дамп — после остановки**, чтобы получить согласованное состояние. Не копировать работающий PostgreSQL data directory как обычную файловую папку.

### Применение Stack-back

Предпочтительно использовать готовый Stack-back для restic/обнаружения volumes/SQL-бэкапа. **Не считать, что `AUTO_BACKUP_ALL=true` автоматически гарантирует согласованный Gitea+PG snapshot.** Агент должен изучить hooks, labels, поведение PostgreSQL adapter и остановки контейнеров, проверить порядок операций и добиться вышеописанной согласованности.

Если Stack-back не даёт надёжно реализовать quiesce + SQL dump + файловый snapshot как **одну восстановимую единицу**, использовать небольшой проверяемый shared backup script + официальный restic. **Не писать полноценную собственную backup-платформу ради Gitea.** Зафиксировать причину выбора в README/ADR.

## 6. Backblaze B2 и политика хранения

- Backup destination задаётся переменной конфигурации, например:

  ```text
  RESTIC_REPOSITORY=s3:https://s3.<region>.backblazeb2.com/<bucket>/services/gitea-prod/restic
  ```

  Адрес — шаблон, endpoint берётся из реальной конфигурации B2. Никаких захардкоженных production credentials.

- Шифрование restic обязательно. Отдельный сильный пароль репозитория и B2 Application Key. Ключи не должны попадать в Git, Docker image, build logs или Terraform state.
- Бэкап: **каждые 6 часов** по умолчанию (конфигурируется). После новой установки предусмотреть запуск первого бэкапа вручную, не дожидаясь расписания.
- Начальная retention policy: **7 daily + 4 weekly + 12 monthly**; значения конфигурируемы. Очистка `forget/prune` выполняется отдельно и безопасно, без конфликтующих backup jobs.
- Еженедельный `restic check` (включая периодическую проверку чтения данных) и **ежемесячный test restore**.
- При неудаче backup/verify — ненулевой exit status, понятный лог и опциональный webhook/heartbeat в Uptime Kuma. Успешный heartbeat не отправлять, если backup не завершён.
- Отдельные credentials с минимальными правами для backup и disaster recovery, насколько позволяет B2. Пароль restic + восстановительные credentials необходимо хранить **вне VPS** (например, в KeePassXC recovery vault).
- Не включать Object Lock/жёсткую S3 retention на рабочем restic repo без отдельного дизайна совместимости с `prune`. Защищённый immutable archive — **опциональный второй этап**, не блокирует MVP.

## 7. First boot / restore: ключевая функция

Интерактивный мастер выполняется **до запуска** приложения. Для `docker compose up -d` нет гарантированного интерактивного терминала, поэтому мастер должен быть отдельной явной командой, например `./manage.sh init` или `./manage.sh restore`. Для автоматизации предусмотреть полностью non-interactive режим с явными параметрами. Не требовать доступности Backrest.

### Требуемые режимы

| Режим | Семантика |
|---|---|
| `init --fresh` | Явно подтверждённая новая пустая установка |
| `init --restore` | Подключиться к существующему restic repository и показать выбор backups |
| `restore --snapshot <id>` | Восстановить **конкретный** snapshot, не «просто latest» |
| `restore --latest` | Явно запрошенный выбор последнего подходящего snapshot |
| `backup now` | Создать проверяемую резервную копию сейчас |
| `backup list` | Показать snapshots для **gitea-prod** |
| `backup verify` | Проверить репозиторий / данные согласно стратегии проверки |
| `status` | Показать состояние Gitea, DB, последнее успешное копирование |

Это **целевой интерфейс** проекта, а не утверждение, что такой CLI уже существует. Названия команд можно слегка изменить, сохраняя смысл и README.

### Интерактивный сценарий

1. Проверить Docker/Compose, наличие секретов, B2 connectivity и права доступа.
2. Определить состояние локальных volumes: `fresh/empty`, `healthy-existing`, `partial-or-unknown`. **Нельзя использовать один marker-файл как единственный источник истины.**
3. Если данные уже существуют и проходят проверку — обычный запуск без restore.
4. Если данных нет — предложить **fresh install** или **restore from B2**; ничего не выбирать молча.
5. По логическому идентификатору `gitea-prod` открыть **настроенный restic repository** и показать подходящие snapshots: timestamp (с timezone), короткий ID, host origin, теги, версия приложения (из manifest при наличии). Не сканировать весь B2 bucket без необходимости.
6. Выбрать snapshot, показать план действий, получить явное подтверждение, восстановить в staging/временные volumes.
7. Проверить наличие и целостность обязательных файлов и дампа, совместимость версий, успешность `pg_restore`, правильность ownership, ключей и конфигурации.
8. Только после успешных проверок переключить рабочие volumes/пути и разрешить запуск Gitea.
9. При сбое остановиться с ненулевым кодом, **не запускать пустую Gitea**, не удалять последнюю работающую копию. Должна быть возможность безопасно повторить restore.

### Особые правила безопасности

- Никогда не выполнять restore **поверх существующей рабочей БД или каталога репозиториев** без явного аварийного режима, двойного подтверждения и сохранения предыдущего состояния.
- Не трактовать `B2 unreachable`, `invalid credentials`, `no snapshots`, `wrong password` как сигнал к созданию новой Gitea.
- Не допускать конкурирующего запуска Gitea во время restore или критической фазы backup. Использовать locks и управление зависимостями Compose.
- Не считать успешный `restic restore` достаточным: результат должен быть проверен запуском Gitea и операциями с данными.
- Для восстановленных volumes PostgreSQL придерживаться корректного официального способа `pg_restore` и инициализации пустой БД; **не смешивать raw PGDATA с логическим дампом**.
- Сохранять и возвращать оригинальные Gitea секреты (`SECRET_KEY`, `INTERNAL_TOKEN`, JWT/OAuth-связанные ключи по фактической конфигурации), иначе часть токенов/зашифрованных настроек может перестать работать.

## 8. Доступы и эксплуатационная безопасность

- `POSTGRES_PASSWORD`, Gitea secret keys, restic password, S3 keys, runner tokens и GHCR token — только в `secrets/` или через secure env/secret files, с `.gitignore`, шаблоном `.env.example` без значений и правами доступа 600/700 по смыслу.
- Убедиться, что `docker compose config`, логи и диагностические команды не раскрывают секреты в документации и выводах CI. По возможности предпочитать Docker Compose `secrets` / `_FILE` там, где образы это поддерживают.
- PostgreSQL доступен только Gitea и maintenance job в частной сети.
- HTTPS на Caddy; корректные secure cookies, доверенные reverse proxy и публичные URL.
- `git.svdk.dev` может быть публичным, но права создания пользователей, репозиториев, токенов и Actions ограничены.
- Контейнеру с Docker socket не давать больше доступа, чем реально требуется; считать Docker socket высокопривилегированным. **CI runner не должен получать production Docker socket.**
- Документировать обновления: pinned versions, backup перед upgrade, restore path для rollback, учёт DB migrations.

## 9. Структура проекта (ориентир, допускается улучшить)

```text
gitea-deployment/
├── compose.yaml                 # Gitea + PostgreSQL + вспомогательные job/services
├── compose.backup.yaml          # если целесообразно вынести backup
├── .env.example                 # без секретов
├── .gitignore
├── config/
│   └── ...                      # несекретные настройки
├── backup/
│   ├── ...                      # Stack-back config / restic settings
│   └── ...                      # только необходимые reusable hooks
├── scripts/
│   ├── manage.sh                # init / restore / backup / status
│   ├── bootstrap.sh
│   ├── restore.sh
│   └── smoke-test.sh
├── docs/
│   ├── OPERATIONS.md            # запуск, upgrade, мониторинг
│   └── DISASTER-RECOVERY.md     # восстановление без старого VPS
└── README.md

# Runtime data and secrets are outside git:
# /srv/gitea/data/            (or dedicated volumes)
# /srv/gitea/postgres/        (or dedicated volumes)
# /srv/gitea/backup-staging/
# /srv/gitea/secrets/
```

Не плодить скрипты ради структуры: объединять мелкие файлы, если так проще и надёжнее. Конечный deployment должен оставаться понятным человеку без знания внутренней реализации AI-агента.

## 10. Приёмочные проверки (обязательны)

Реализовать и документировать проверки, желательно автоматизировать smoke tests:

### A. Чистая установка
- [ ] На чистых volumes команда явного `init --fresh` создаёт новую Gitea.
- [ ] `docker compose up -d` поднимает Gitea + PostgreSQL с health checks.
- [ ] Web UI, HTTPS, Git clone/push работают.
- [ ] Packages disabled, Actions enabled.
- [ ] Можно создать PR; статусы CI появляются в Gitea; branch protection блокирует merge при красном CI (runner запускается в изоляции).

### B. Резервная копия
- [ ] Создать тестовые Git-репозитории, ветку, PR, Issue, attachment, LFS-файл (если включён) и пользователя.
- [ ] Запустить `backup now`; в B2 появляется **один логический восстановимый snapshot** со всем необходимым.
- [ ] Убедиться, что PostgreSQL представлен консистентным дампом, а Git-файлы соответствуют состоянию БД.
- [ ] Посмотреть snapshots через CLI, выполнить проверку, убедиться, что не сохранены caches и PGDATA.
- [ ] Проверить поведение при недоступном B2: backup fails, Gitea остаётся живой, об успехе не сообщается.

### C. Disaster recovery
- [ ] На **отдельном чистом** Docker host / VM восстановиться из B2 без доступа к старой машине.
- [ ] Мастер показывает доступные snapshots `gitea-prod`; можно выбрать не самый новый.
- [ ] Восстанавливаются PostgreSQL, Git repositories, LFS/attachments, пользователи, PR, Issues и секреты.
- [ ] После запуска работают Git clone/fetch/push и просмотр PR/Issues.
- [ ] Повторный `docker compose up -d` **не запускает restore снова**.
- [ ] При неверном restic password, пустом bucket или прерванном restore приложение **не стартует пустым**.
- [ ] При обнаружении нераспознанных непустых volumes приложение отказывается от destructive actions.

### D. Переносимость
- [ ] Изменение hostname/VPS не меняет путь backup repository `services/gitea-prod/restic`.
- [ ] Порядок первого запуска, подключения к Caddy и восстановления описан в README.
- [ ] Для следующего Compose-сервиса reusable backup/restore-компоненты можно использовать через конфигурацию, а не переписывать с нуля.

**Если нет возможности выполнить тест с реальным B2:** предусмотреть MinIO как локальную S3-совместимую тестовую среду; явно пометить, какие проверки были проведены с MinIO, а какие с B2. Не утверждать, что восстановление с B2 протестировано, без фактического теста.

## 11. Ожидаемый результат работы агента

Нужно вернуть **реальные файлы проекта** и короткий отчёт:

1. Работающий, проверенный `compose.yaml`, конфигурации и необходимые bootstrap/backup/restore-скрипты.
2. `.env.example`, `.gitignore`, пример команд первого запуска, подключения B2, создания первого backup, выбора snapshot и восстановления.
3. Документы `README.md`, `OPERATIONS.md`, `DISASTER-RECOVERY.md`.
4. Описание выбранного механизма backup (Stack-back или fallback), включая доказательство согласованности PostgreSQL + Git.
5. Результаты `docker compose config`, проверок smoke test, процесса аварийного восстановления и явный список того, что не удалось проверить.
6. Никаких реальных production secrets в исходниках или демонстрационных логах.

Агент должен **самостоятельно выполнять разумные технические проверки** и не останавливаться после создания красивого Compose-файла. Приоритет — надёжность реального restore, затем удобство, затем минимализм.

## 12. Чего НЕ делать в этой версии

- Не строить active-active Gitea, PostgreSQL HA, Patroni, Ceph, Kubernetes или сложный кластер.
- Не внедрять Terraform, Ansible, Vault, Keycloak/Authentik без прямой необходимости.
- Не поднимать ещё один Caddy или отдельный Docker Registry.
- Не переносить Git-репозитории на S3/s3fs/rclone mount.
- Не переносить LFS/attachments в S3 на старте: локальное хранение + restic достаточно; миграцию можно сделать позже.
- Не хранить source of truth для восстановления **только в самой Gitea**; deployment repo и recovery-инструкция должны оставаться доступны независимо от падения Gitea.
- Не разрабатывать абстрактный сложный framework для сотни сервисов, если достаточен один повторно используемый backup/restore mechanism.
- Не удалять данные, не выполнять destructive rollback и не выбирать restore snapshot без явного намерения оператора.

## 13. Источники / документы для реализации

- Gitea Docker installation: https://docs.gitea.com/installation/install-with-docker
- Gitea config cheat sheet: https://docs.gitea.com/1.27/administration/config-cheat-sheet/
- Gitea backup consistency: https://docs.gitea.com/1.27/administration/backup-and-restore/
- Gitea Actions / runner: https://docs.gitea.com/runner/2/registration/
- Docker Compose startup dependencies: https://docs.docker.com/compose/how-tos/startup-order/
- Stack-back: https://github.com/lawndoc/stack-back
- Restic: https://restic.readthedocs.io/
- Backblaze B2 S3 API: https://www.backblaze.com/cloud-storage/features/s3-compatible

> **Основной product requirement:** `git.svdk.dev` должен быть **воспроизводимым сервисом с проверяемым восстановлением из B2**, а не уникальным VPS, потеря которого приводит к потере Git-истории и настроек. Простота обслуживания важнее гипотетической высокой доступности.
