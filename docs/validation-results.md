# Проверка Ясно 0.2.3

18 октября 2026. Профиль `full`, seed `20261018`. 123 XCTest и 7 Python-проверок прошли.

**703 467 сценариев, 0 обязательных ошибок.** Сравнение с 0.2.2: 0 новых несовпадений и 0 изменённых несовпадений.

Новые проверки `Пшерги` → `Github` и `bpex` → «изуч» закреплены отдельно в `ReportedWordTests`. Корпус полного прогона сохранён для строгого сравнения с предыдущей версией. [Причины и изменения](word-fixes-0.2.3.md).

Исследовательские опечатки имеют заданное намерение, которое может быть неоднозначным. Пропуски и другие результаты не считаются успешными исправлениями.

| Категория | Проверок | Совпадений | Сохранённый ввод | Другой результат / раскладка |
|---|---:|---:|---:|---:|
| domains | 16000 | 16000 | 0 | 0 |
| exclusions | 1905 | 1905 | 0 | 0 |
| golden-layout | 80 | 80 | 0 | 0 |
| golden-live | 10 | 10 | 0 | 0 |
| golden-spelling | 13 | 13 | 0 | 0 |
| layout-coverage | 1905 | 1859 | 46 | 0 |
| layout-only-coverage | 1905 | 1859 | 46 | 0 |
| layout-plus-typo-coverage | 35994 | 22698 | 12092 | 1204 |
| lexicon-native-audit | 173168 | 173126 | 0 | 42 |
| lexicon-prefix-audit | 173168 | 173168 | 0 | 0 |
| manual-coverage | 1905 | 1854 | 0 | 51 |
| native-prefix | 8396 | 8396 | 0 | 0 |
| native-preservation | 9064 | 9064 | 0 | 0 |
| physical-stream-coverage | 1905 | 1859 | 46 | 0 |
| protected-fuzz | 240000 | 240000 | 0 | 0 |
| protected-patterns | 129 | 129 | 0 | 0 |
| spelling-disabled | 13 | 13 | 0 | 0 |
| spelling-excluded | 13 | 13 | 0 | 0 |
| typo-duplication-coverage | 7884 | 6308 | 1576 | 0 |
| typo-insertion-coverage | 7579 | 6288 | 1291 | 0 |
| typo-omission-coverage | 7884 | 3679 | 4204 | 1 |
| typo-substitution-coverage | 7700 | 5184 | 2515 | 1 |
| typo-transposition-coverage | 6847 | 5015 | 1832 | 0 |

Движок: 21.0 с; p50/p95/p99: 3/228/406 мкс. Это время анализатора, а не браузерного IPC.

Полный отчёт: `.build/validation/full-20261018/`. База: `.build/validation/baseline-0.2.2-full-20261018/`. Журнал: `.build/validation-0.2.3.log`.

Предыдущий отчёт: [0.2.2](validation-results-0.2.2.md). Тесты движка и симуляция не сертифицируют физический ввод во всех внешних приложениях.
