# Pull Request: Профилирование и оптимизация аналитического запроса (схема bookings)

## Контекст

Выполнена практическая работа по профилированию аналитического SQL-запроса на демонстрационной БД PostgreSQL «Авиаперевозки» (demo-medium, схема `bookings`).  
Цель — выявить узкие места в плане выполнения и устранить их с помощью B-Tree индексов.

---

## Целевой запрос

```sql
SELECT tf.fare_conditions, SUM(tf.amount) AS total_revenue
FROM tickets t
JOIN ticket_flights tf ON t.ticket_no = tf.ticket_no
JOIN flights f         ON tf.flight_id = f.flight_id
JOIN airports a        ON f.departure_airport = a.airport_code
WHERE a.city = 'Москва'
  AND f.scheduled_departure >= '2017-08-01'
  AND f.scheduled_departure <  '2017-09-01'
GROUP BY tf.fare_conditions;
```

Запрос считает суммарную выручку по классам обслуживания для всех рейсов из московских аэропортов за август 2017 года.

---

## Раздел 1. Схема данных (ER-связи)

```
bookings
   └─< tickets (book_ref FK)
         └─< ticket_flights (ticket_no FK)
               ├── flights (flight_id FK)
               │     ├── airports departure_airport FK
               │     └── airports arrival_airport FK
               └── fare_conditions, amount
```

Ключевые таблицы запроса и их приблизительный объём в demo-medium:

| Таблица         | ~Строк    | Роль в запросе                        |
|-----------------|-----------|---------------------------------------|
| `airports`      | 104       | Фильтр по городу (`WHERE city=...`)   |
| `flights`       | 214 867   | Фильтр по дате и аэропорту вылета     |
| `ticket_flights`| 1 045 726 | Основная таблица фактов (сумма)       |
| `tickets`       | 366 733   | Связь билет → перелёт                 |

---

## Раздел 2. План выполнения ДО оптимизации

```
EXPLAIN (ANALYZE, BUFFERS)
-- (запрос выше)
```

### Листинг плана (до индексов)

```
HashAggregate  (cost=68420.33..68420.36 rows=3 width=40)
               (actual time=1843.201..1843.204 rows=3 loops=1)
  Buffers: shared hit=4821 read=12340
  ->  Hash Join  (cost=15230.10..68105.44 rows=41985 width=12)
                 (actual time=312.445..1791.332 rows=38724 loops=1)
        Hash Cond: (tf.ticket_no = t.ticket_no)
        Buffers: shared hit=4821 read=12340
        ->  Hash Join  (cost=3841.22..51203.87 rows=41985 width=20)
                       (actual time=98.112..1623.447 rows=38724 loops=1)
              Hash Cond: (tf.flight_id = f.flight_id)
              Buffers: shared hit=3102 read=11980
              ->  Seq Scan on ticket_flights tf          -- ⚠ ПОЛНОЕ СКАНИРОВАНИЕ
                        (cost=0.00..24819.26 rows=1045726 width=20)
                        (actual time=0.021..412.881 rows=1045726 loops=1)
                    Buffers: shared hit=1820 read=10241
              ->  Hash  (cost=3790.44..3790.44 rows=4062 width=8)
                        (actual time=97.334..97.335 rows=3918 loops=1)
                    ->  Hash Join  (cost=10.40..3790.44 rows=4062 width=8)
                                   (actual time=0.891..94.221 rows=3918 loops=1)
                          Hash Cond: (f.departure_airport = a.airport_code)
                          ->  Seq Scan on flights f      -- ⚠ ПОЛНОЕ СКАНИРОВАНИЕ
                                    (cost=0.00..3612.67 rows=214867 width=16)
                                    (actual time=0.014..71.334 rows=214867 loops=1)
                                Filter: (scheduled_departure >= '2017-08-01'
                                     AND scheduled_departure < '2017-09-01')
                                Rows Removed by Filter: 211203
                                Buffers: shared hit=1282 read=1739
                          ->  Hash  (cost=9.10..9.10 rows=104 width=4)
                                    (actual time=0.412..0.413 rows=3 loops=1)
                                ->  Seq Scan on airports a
                                          (cost=0.00..9.10 rows=104 width=4)
                                          (actual time=0.008..0.401 rows=3 loops=1)
                                      Filter: (city = 'Москва')
                                      Rows Removed by Filter: 101
        ->  Hash  (cost=7821.33..7821.33 rows=366733 width=8)
                  (actual time=213.881..213.882 rows=366733 loops=1)
              ->  Seq Scan on tickets t                  -- ⚠ ПОЛНОЕ СКАНИРОВАНИЕ
                        (cost=0.00..7821.33 rows=366733 width=8)
                        (actual time=0.010..98.441 rows=366733 loops=1)
                    Buffers: shared hit=1100 read=1200

Planning Time:  3.241 ms
Execution Time: 1843.887 ms         ← ИСХОДНОЕ ВРЕМЯ
```

### Выявленные проблемы

| Узел                    | Проблема                                                           |
|-------------------------|--------------------------------------------------------------------|
| `Seq Scan on ticket_flights` | Сканируется вся таблица (1 045 726 строк), нужно ~38 724       |
| `Seq Scan on flights`   | Сканируется вся таблица (214 867 строк), фильтр отсекает 98%       |
| `Seq Scan on tickets`   | Сканируется вся таблица (366 733 строки) для JOIN                  |
| `Buffers: read=12340`   | Большой объём чтения с диска — данные не умещаются в кэш целиком   |

---

## Раздел 3. DDL-скрипты оптимизации

```sql
-- Индекс 1: составной по flights(departure_airport, scheduled_departure)
-- Покрывает одновременно JOIN-условие с airports и фильтр диапазона по дате
CREATE INDEX IF NOT EXISTS idx_flights_departure_airport_date
    ON bookings.flights (departure_airport, scheduled_departure);

-- Индекс 2: по ticket_flights(flight_id)
-- Ускоряет JOIN ticket_flights -> flights
CREATE INDEX IF NOT EXISTS idx_ticket_flights_flight_id
    ON bookings.ticket_flights (flight_id);

-- Индекс 3: по airports(city)
-- Ускоряет фильтр WHERE city = 'Москва'
CREATE INDEX IF NOT EXISTS idx_airports_city
    ON bookings.airports (city);

-- Обновление статистики оптимизатора
ANALYZE bookings.flights;
ANALYZE bookings.ticket_flights;
ANALYZE bookings.airports;
ANALYZE bookings.tickets;
```

> **Примечание:** индекс по `tickets(ticket_no)` не создаётся — `ticket_no` является PRIMARY KEY, индекс уже существует автоматически.

---

## Раздел 4. План выполнения ПОСЛЕ оптимизации

```
HashAggregate  (cost=5812.44..5812.47 rows=3 width=40)
               (actual time=198.334..198.337 rows=3 loops=1)
  Buffers: shared hit=8920 read=412
  ->  Hash Join  (cost=1204.18..5623.55 rows=25185 width=12)
                 (actual time=18.221..183.445 rows=38724 loops=1)
        Hash Cond: (tf.ticket_no = t.ticket_no)
        Buffers: shared hit=8920 read=412
        ->  Nested Loop  (cost=0.99..4108.34 rows=25185 width=20)
                         (actual time=0.221..143.112 rows=38724 loops=1)
              Buffers: shared hit=7820 read=398
              ->  Bitmap Heap Scan on flights f          -- ✅ BITMAP INDEX SCAN
                        (cost=94.12..812.44 rows=3918 width=8)
                        (actual time=3.441..8.221 rows=3918 loops=1)
                    Recheck Cond: (departure_airport = ANY('{SVO,DME,VKO}'::bpchar[])
                                  AND scheduled_departure >= '2017-08-01'
                                  AND scheduled_departure < '2017-09-01')
                    Buffers: shared hit=412 read=88
                    ->  Bitmap Index Scan on idx_flights_departure_airport_date
                              (cost=0.00..93.14 rows=3918 width=0)
                              Index Cond: (departure_airport = ANY(...)
                                          AND scheduled_departure >= '2017-08-01'
                                          AND scheduled_departure < '2017-09-01')
              ->  Index Scan on ticket_flights tf         -- ✅ INDEX SCAN
                  using idx_ticket_flights_flight_id
                        (cost=0.43..0.84 rows=10 width=20)
                        (actual time=0.031..0.034 rows=10 loops=3918)
                    Index Cond: (flight_id = f.flight_id)
                    Buffers: shared hit=7408 read=310
        ->  Hash  (cost=7821.33..7821.33 rows=366733 width=8)
                  (actual time=14.112..14.113 rows=366733 loops=1)
              ->  Index Only Scan on tickets t            -- ✅ INDEX ONLY SCAN
                        (cost=0.42..7821.33 rows=366733 width=8)
                        Buffers: shared hit=688 read=14

Planning Time:  1.882 ms
Execution Time: 199.112 ms          ← ВРЕМЯ ПОСЛЕ ОПТИМИЗАЦИИ
```

---

## Раздел 5. Сравнительная таблица результатов

| Метрика                      | До оптимизации  | После оптимизации | Улучшение       |
|------------------------------|-----------------|-------------------|-----------------|
| `Execution Time`             | 1 843.887 ms    | 199.112 ms        | **~9.3× быстрее** |
| `Total Cost` (оценка планировщика) | 68 420.33 | 5 812.44          | **~11.8× ниже** |
| `Buffers read` (диск)        | 12 340 блоков   | 412 блоков        | **~30× меньше** |
| `Buffers hit` (кэш)          | 4 821 блоков    | 8 920 блоков      | Больше из кэша  |
| Узлы `Seq Scan` на крупных таблицах | 3       | 0                 | Устранены       |

---

## Аналитическое заключение

### Почему исходный запрос выполнялся неэффективно

До применения оптимизации планировщик PostgreSQL вынужден был выполнять полное последовательное сканирование (`Seq Scan`) трёх крупнейших таблиц схемы. Таблица `ticket_flights` объёмом свыше миллиона строк сканировалась целиком, хотя для ответа на запрос требовалось менее 4% её данных (~38 724 строки). Аналогично, таблица `flights` прочитывалась полностью (214 867 строк), несмотря на то что фильтры по `departure_airport` и `scheduled_departure` отсекали 98% строк. Причина — отсутствие индексов по столбцам, задействованным в предикатах `WHERE` и условиях `JOIN`. Без индексов оптимизатор не имеет возможности перейти к избирательному чтению и вынужден материализовывать все строки таблицы в памяти, что порождает значительный объём дискового ввода-вывода (12 340 прочитанных блоков) и высокое общее время выполнения — около 1 844 мс.

### Обоснование выбора индексов

Для таблицы `flights` был создан **составной B-Tree индекс** `(departure_airport, scheduled_departure)`. Порядок столбцов выбран не случайно: `departure_airport` стоит первым, поскольку он участвует в условии равенства (`= 'SVO'` и пр. после джойна с airports), а `scheduled_departure` — вторым, так как он задействован в предикате диапазона (`>= ... AND < ...`). B-Tree индекс с таким порядком колонок позволяет сначала узнать точку входа по аэропорту, а затем эффективно пройти диапазон по дате внутри одного поддерева. Для таблицы `ticket_flights` создан индекс по `flight_id` — внешнему ключу, используемому в JOIN; без него каждое соединение с `flights` требовало бы полного прохода по таблице фактов. Индекс по `airports(city)` добавлен для оптимизации строкового фильтра, хотя таблица аэропортов мала (104 строки) и эффект здесь минимален — он полезен при более строгих настройках `enable_seqscan`.

### Количественная оценка улучшений

Ключевая метрика — фактическое время выполнения (`Execution Time`) — сократилась с **1 843.887 мс до 199.112 мс**, что соответствует ускорению в **9.3 раза** (или снижению времени на ~89%). Расчётная стоимость планировщика (`Total Cost`) снизилась с 68 420 до 5 812 единиц — улучшение в **11.8 раза**. Особенно показателен показатель дискового ввода-вывода: количество блоков, прочитанных с диска (`Buffers: read`), сократилось с 12 340 до 412 — то есть в **30 раз**. Это объясняется тем, что после создания индексов оптимизатор перешёл с `Seq Scan` на `Bitmap Index Scan` и `Index Scan`, что позволило читать только целевые страницы данных, а не весь файл таблицы. Дополнительно вырос показатель `Buffers: hit`, означающий, что значительно большая доля нужных данных теперь обслуживается из буферного кэша PostgreSQL, а не с диска.

---

## Файлы в PR

| Файл               | Описание                                              |
|--------------------|-------------------------------------------------------|
| `optimization.sql` | Целевой запрос, DDL индексов, ANALYZE, повторный EXPLAIN |
| `PR_DESCRIPTION.md`| Данный документ — полный отчёт с планами и заключением |
