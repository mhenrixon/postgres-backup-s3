-- Seed data for E2E backup/restore test.
-- Runs automatically on first start via /docker-entrypoint-initdb.d/.

CREATE TABLE users (
  id         bigserial PRIMARY KEY,
  email      text        NOT NULL UNIQUE,
  full_name  text        NOT NULL,
  signup_at  timestamptz NOT NULL DEFAULT now(),
  payload    jsonb       NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX users_signup_at_idx ON users (signup_at);

INSERT INTO users (email, full_name, signup_at, payload)
SELECT
  'user' || i || '_' || substr(md5(random()::text), 1, 8) || '@example.com',
  'User ' || i,
  now() - (random() * interval '365 days'),
  jsonb_build_object(
    'score',  (random() * 1000)::int,
    'tier',   (array['free','pro','enterprise'])[1 + floor(random() * 3)::int],
    'tags',   (array['alpha','beta','gamma','delta'])[1 + floor(random() * 4)::int]
  )
FROM generate_series(1, 5000) AS s(i);
