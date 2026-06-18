-- =============================================
-- Раздел 2. Целевой аналитический запрос
-- =============================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT tf.fare_conditions, SUM(tf.amount) AS total_revenue
FROM tickets t
JOIN ticket_flights tf ON t.ticket_no = tf.ticket_no
JOIN flights f         ON tf.flight_id = f.flight_id
JOIN airports a        ON f.departure_airport = a.airport_code
WHERE a.city = 'Москва'
  AND f.scheduled_departure >= '2017-08-01'
  AND f.scheduled_departure <  '2017-09-01'
GROUP BY tf.fare_conditions;


-- =============================================
-- Раздел 3. DDL-скрипты оптимизации
-- =============================================

-- Индекс 1: составной индекс по flights
-- Покрывает фильтр по диапазону scheduled_departure
-- и условие соединения по departure_airport (JOIN с airports)
CREATE INDEX IF NOT EXISTS idx_flights_departure_airport_date
    ON bookings.flights (departure_airport, scheduled_departure);

-- Индекс 2: индекс по ticket_flights(flight_id)
-- Ускоряет JOIN ticket_flights -> flights по flight_id
-- (в демо-БД первичный ключ ticket_flights составной:
--  (ticket_no, flight_id), но отдельного индекса по flight_id нет)
CREATE INDEX IF NOT EXISTS idx_ticket_flights_flight_id
    ON bookings.ticket_flights (flight_id);

-- Индекс 3: индекс по tickets(ticket_no) — обычно уже есть как PK,
-- но явно проверяем наличие для JOIN tickets -> ticket_flights
-- CREATE INDEX IF NOT EXISTS idx_tickets_ticket_no
--     ON bookings.tickets (ticket_no);
-- (закомментирован: ticket_no является PRIMARY KEY, индекс уже существует)

-- Индекс 4: индекс по airports(city)
-- Ускоряет фильтр WHERE a.city = 'Москва'
CREATE INDEX IF NOT EXISTS idx_airports_city
    ON bookings.airports (city);


-- =============================================
-- Раздел 3.4. Обновление статистики оптимизатора
-- =============================================

ANALYZE bookings.flights;
ANALYZE bookings.ticket_flights;
ANALYZE bookings.airports;
ANALYZE bookings.tickets;


-- =============================================
-- Раздел 4. Повторное профилирование
-- =============================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT tf.fare_conditions, SUM(tf.amount) AS total_revenue
FROM tickets t
JOIN ticket_flights tf ON t.ticket_no = tf.ticket_no
JOIN flights f         ON tf.flight_id = f.flight_id
JOIN airports a        ON f.departure_airport = a.airport_code
WHERE a.city = 'Москва'
  AND f.scheduled_departure >= '2017-08-01'
  AND f.scheduled_departure <  '2017-09-01'
GROUP BY tf.fare_conditions;
