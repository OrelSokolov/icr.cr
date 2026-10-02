# Запечённая таблица автокомплита для icr

Цель: при сборке приложения, в которое icr подключён как библиотека,
«запекать» таблицу типов и методов всей программы (классы автоматически,
модули — через явные корни) и использовать её в консоли для автокомплита
(Tab) и fuzzy-поиска (Ctrl-T).

## Проверенная база (спайки на Crystal 1.21)

| Возможность | Статус |
|---|---|
| `macro finished` на верхнем уровне видит типы всей программы | ✅ |
| `Object.all_subclasses` — все классы/структуры (в минимальной программе 792, включая stdlib) | ✅ |
| `Foo.methods` / `Foo.class.methods`: `name`, `args` (имя/тип/дефолт), `return_type`, `visibility`, `doc` | ✅ |
| Примеси видимы через `klass.ancestors` (плоский список) | ✅ |
| Реестр корней: `@[Root(Path)]` → `ann.args.first.resolve` → TypeNode (включая вложенные `Deep::Util`) | ✅ |
| Масштаб: 36 469 записей / 1.5 МБ строка / +0.2 с компиляции / бинарник 3.7 МБ | ✅ |
| `TypeNode#types`, `MacroId#resolve`/`resolve?`, `Def#file` | ❌ нет в 1.21 |

Следствие: автоматически обходятся только классы/структуры; модули и
enum'ы в иерархию `Object` не входят, а имена из `@type.constants` нельзя
превратить обратно в TypeNode. Поэтому модули передаются явными корнями —
это и есть `require_with_autocomplete`.

## Фаза 1 — сбор урожая на этапе компиляции (`src/icr/completion.cr`)

- `annotation Icr::Root` — несёт путь к типу-корню (Path, резолвится в
  конце компиляции, так что форвард-ссылки допустимы).
- `annotation Icr::Enabled` — «включить сбор» без корней (для CLI).
- Топ-левел макрос `require_with_autocomplete(path, *roots)`:
  - разворачивается в `require {{ path }}` (относительный путь
    резолвится от файла-вызовителя);
  - на каждый корень emits маркерный def с `@[::Icr::Root(root)]`
    (имя маркера уникально: файл+строка вызова, гашёные в валидное имя).
- `macro Icr.enable_autocomplete!` — emits маркер с `@[::Icr::Enabled]`
  (включает сбор без корней; используется `src/cli.cr`, чтобы отдельная
  консоль получала таблицу stdlib+icr).
- Топ-левел `macro finished` (живёт в icr, срабатывает в любом бинарнике
  с icr):
  - нет маркеров → `Icr::Completion::TABLE = ""`, накладных расходов ноль;
  - есть → собирает: корни из аннотаций ∪ `Object.all_subclasses` ∪ их
    `ancestors`; для каждого типа: T-строка (имя, вид), A-строки
    (предки), M-строки (публичные методы, instance + self: имя, args с
    типами/дефолтами, return type), C-строки (имена констант);
  - фильтры: private/protected, операторы (имя не «слово»), `allocate`,
    `new`, `initialize`; имена дженериков нормализуются `Array(T)` →
    `Array`;
  - запекает одну строку-TSV константу `Icr::Completion::TABLE`
    (колонки: T/A/M/C; формат ниже). Дедупликация — в рантайме.

Формат TSV (первое поле — вид строки):

```
T\t<full type name>\t<module|class|struct>
A\t<type>\t<ancestor>
M\t<owner>\t<i|s>\t<method name>\t<args>\t<return type>
C\t<owner>\t<constant name>
```

## Фаза 2 — рантайм-индекс (`src/icr/completion_index.cr`)

- `Icr::Completion::Index`:
  - ленивый парсер `TABLE` (дедуп через Set) в структуры:
    `types`, `ancestors`, `entries` (owner → методы), `constants`;
  - `Index.default` — синглтон из `TABLE`;
  - запросы: `type?(name)`, `member_names(type)` (instance-методы с
    наследованием по A-строкам), `self_method_names(type)`,
    `completions(prefix)` (имена типов по префиксу),
    `search(query, limit)` — substring/subsequence-скоринг по
    «Owner.name» / «Owner#name».
- `Icr::Completion::Completer` — чистая логика завершения токена:
  - `Foo.sq<Tab>` → self-методы типа `Foo`;
  - `MyM<Tab>` → имена типов + немного keyword'ов;
  - возвращает {вставка общего префикса, список кандидатов}.

## Фаза 3 — Tab в редакторе (`src/icr/editor.cr`)

- `Key::Tab` (байт 9), парсинг; `EditState#insert_text(text)`.
- `UnixLineEditor`: Tab → Completer; вставка общего префикса, при
  неоднозначности без прогресса — печать кандидатов под строкой (irb-style).
- `LineEditor.new(index)` — индекс пробрасывается адаптеру; BasicLineEditor
  без изменений (не TTY — Tab отбрасывается как Unknown).

## Фаза 4 — Ctrl-T «серч-терминал» и обвязка

- Оверлей в `UnixLineEditor`: query-строка (мини-редактор на EditState),
  топ-10 совпадений, ↑/↓ выбор, Enter — вставка (`Type.name(` для
  self-методов, `name(` для instance), Ctrl-C/Ctrl-D — отмена.
- Обвязка:
  - `src/cli.cr`: `Icr.enable_autocomplete!` + индекс в редактор;
  - `examples/library_demo.cr`: `require_with_autocomplete "./my_math", MyMath`;
  - баннер: подсказка про Tab/Ctrl-T;
  - README: раздел Autocomplete.

## Спеки

- Unit: парсер индекса (фикстурная TABLE), Completer, KeyParser
  (Tab/CtrlT), EditState#insert_text.
- E2E (компиляция фикстуры через `crystal run`, как в спеках replay):
  программа с `require_with_autocomplete` печатает типы/методы MyMath из
  запечённой таблицы.

## Ограничения (принятые)

- Таблица — снапшот на сборке; классы, определённые позже в самой сессии
  REPL, в неё не попадают (опционально позже: regex-скан
  `session.program_source` на `def`/`class`/`module` и слияние).
- Модули и enum'ы требуют явных корней (фундаментальное ограничение
  1.21: нет резолва имён констант).
- Нижний регистр-ресиверы (переменные) не дополняются: тип значения в
  рантайме неизвестен хост-процессу.
- `macro finished` icr исполняется в каждом бинарнике с icr — поэтому
  без маркеров таблица пустая (нулевая цена).
