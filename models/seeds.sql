-- Shared demo literals used by the seed statements below.
DROP TABLE IF EXISTS seed_constants;

CREATE TEMP TABLE seed_constants (
    demo_password_hash TEXT NOT NULL,
    light_theme TEXT NOT NULL,
    dark_theme TEXT NOT NULL,
    email_verify_token_type TEXT NOT NULL,
    password_reset_token_type TEXT NOT NULL,
    default_token_expires_at TIMESTAMP NOT NULL,
    default_token_created_at TIMESTAMP NOT NULL,
    campaign_started_at TIMESTAMP NOT NULL,
    user_login_activity TEXT NOT NULL
);

INSERT INTO seed_constants (
    demo_password_hash,
    light_theme,
    dark_theme,
    email_verify_token_type,
    password_reset_token_type,
    default_token_expires_at,
    default_token_created_at,
    campaign_started_at,
    user_login_activity
) VALUES (
    '$2b$12$Y6jhLOeIm2SNmZZDqt9LsOZbtu2I2GQBMN23w0gcfVjHV3MWtKHhG',
    'light',
    'dark',
    'email_verify',
    'password_reset',
    TIMESTAMP '2026-05-10 12:00:00',
    TIMESTAMP '2026-05-03 10:00:00',
    TIMESTAMP '2026-05-01 08:00:00',
    'user_login'
);

-- Insert Seed Data into `users` table
WITH seed_users (username, email, first_name, last_name, avatar_url, bio, use_dark_theme, notifications_enabled, is_email_verified, created_at, updated_at) AS (
    VALUES
        ('johndoe', 'john.doe@example.com', 'John', 'Doe', 'https://example.com/avatars/john.png', 'Software engineer passionate about building SaaS products.', FALSE, TRUE, TRUE, TIMESTAMP '2026-01-10 10:00:00', TIMESTAMP '2026-01-10 10:00:00'),
        ('janedoe', 'jane.doe@example.com', 'Jane', 'Doe', 'https://example.com/avatars/jane.png', 'Product designer and illustrator.', TRUE, TRUE, TRUE, TIMESTAMP '2026-01-11 11:30:00', TIMESTAMP '2026-01-12 09:15:00'),
        ('alice_w', 'alice@example.com', 'Alice', 'Williams', 'https://example.com/avatars/alice.png', 'Content marketer and strategist.', FALSE, FALSE, TRUE, TIMESTAMP '2026-01-15 14:00:00', TIMESTAMP '2026-01-15 14:00:00'),
        ('bob_dev', 'bob@example.com', 'Bob', 'Smith', 'https://example.com/avatars/bob.png', 'Backend developer in love with Rust and Go.', TRUE, TRUE, FALSE, TIMESTAMP '2026-02-01 08:00:00', TIMESTAMP '2026-02-01 08:00:00'),
        ('charlie_c', 'charlie@example.com', 'Charlie', 'Chaplin', NULL, NULL, FALSE, TRUE, TRUE, TIMESTAMP '2026-02-10 16:20:00', TIMESTAMP '2026-02-15 10:45:00'),
        ('diana_p', 'diana@example.com', 'Diana', 'Prince', 'https://example.com/avatars/diana.png', 'Data enthusiast and analyst.', TRUE, FALSE, TRUE, TIMESTAMP '2026-02-14 09:00:00', TIMESTAMP '2026-02-14 09:00:00'),
        ('evan_r', 'evan@example.com', 'Evan', 'Wright', NULL, 'Freelance writer.', FALSE, TRUE, TRUE, TIMESTAMP '2026-02-20 17:10:00', TIMESTAMP '2026-02-20 17:10:00'),
        ('fiona_g', 'fiona@example.com', 'Fiona', 'Gallagher', 'https://example.com/avatars/fiona.png', 'Digital nomad, writing code from anywhere.', TRUE, TRUE, FALSE, TIMESTAMP '2026-03-01 12:00:00', TIMESTAMP '2026-03-02 14:30:00'),
        ('george_h', 'george@example.com', 'George', 'Harrison', 'https://example.com/avatars/george.png', 'Musician and developer.', FALSE, TRUE, TRUE, TIMESTAMP '2026-03-05 13:15:00', TIMESTAMP '2026-03-05 13:15:00'),
        ('hannah_b', 'hannah@example.com', 'Hannah', 'Baker', NULL, 'Customer success representative.', FALSE, TRUE, TRUE, TIMESTAMP '2026-03-10 15:40:00', TIMESTAMP '2026-03-10 15:40:00')
)
INSERT INTO users (username, email, password_hash, first_name, last_name, avatar_url, bio, theme, notifications_enabled, is_email_verified, created_at, updated_at)
SELECT
    u.username,
    u.email,
    c.demo_password_hash,
    u.first_name,
    u.last_name,
    u.avatar_url,
    u.bio,
    CASE WHEN u.use_dark_theme THEN c.dark_theme ELSE c.light_theme END,
    u.notifications_enabled,
    u.is_email_verified,
    u.created_at,
    u.updated_at
FROM seed_users u
CROSS JOIN seed_constants c;

-- Insert Seed Data into `user_tokens` table
WITH seed_tokens (user_id, token, is_email_verify, expires_at, created_at) AS (
    VALUES
        (1, 'abc123xyz_verify_token_1', TRUE, NULL, NULL),
        (2, 'abc123xyz_verify_token_2', FALSE, TIMESTAMP '2026-05-04 10:00:00', TIMESTAMP '2026-05-03 09:00:00'),
        (3, 'abc123xyz_verify_token_3', TRUE, NULL, NULL),
        (4, 'abc123xyz_verify_token_4', TRUE, TIMESTAMP '2026-05-04 08:00:00', NULL),
        (5, 'abc123xyz_verify_token_5', FALSE, TIMESTAMP '2026-05-05 15:00:00', TIMESTAMP '2026-05-03 11:00:00'),
        (6, 'abc123xyz_verify_token_6', TRUE, NULL, NULL),
        (7, 'abc123xyz_verify_token_7', TRUE, NULL, NULL),
        (8, 'abc123xyz_verify_token_8', FALSE, NULL, TIMESTAMP '2026-05-03 12:00:00'),
        (9, 'abc123xyz_verify_token_9', TRUE, NULL, NULL),
        (10, 'abc123xyz_verify_token_10', TRUE, NULL, NULL)
)
INSERT INTO user_tokens (user_id, token, token_type, expires_at, created_at)
SELECT
    t.user_id,
    t.token,
    CASE WHEN t.is_email_verify THEN c.email_verify_token_type ELSE c.password_reset_token_type END,
    COALESCE(t.expires_at, c.default_token_expires_at),
    COALESCE(t.created_at, CASE WHEN t.user_id = 4 THEN c.campaign_started_at ELSE c.default_token_created_at END)
FROM seed_tokens t
CROSS JOIN seed_constants c;

-- Insert Seed Data into `sessions` table
WITH seed_sessions (user_id, session_token, expires_at, created_at) AS (
    VALUES
        (1, 'sess_tok_01a2b3c4d5', TIMESTAMP '2026-05-10 10:00:00', NULL),
        (2, 'sess_tok_02b3c4d5e6', TIMESTAMP '2026-05-10 11:30:00', TIMESTAMP '2026-05-03 11:30:00'),
        (3, 'sess_tok_03c4d5e6f7', TIMESTAMP '2026-05-10 14:00:00', TIMESTAMP '2026-05-03 14:00:00'),
        (4, 'sess_tok_04d5e6f7a8', TIMESTAMP '2026-05-08 08:00:00', NULL),
        (5, 'sess_tok_05e6f7a8b9', TIMESTAMP '2026-05-08 16:20:00', TIMESTAMP '2026-05-03 10:20:00'),
        (6, 'sess_tok_06f7a8b9c0', TIMESTAMP '2026-05-09 09:00:00', TIMESTAMP '2026-05-02 09:00:00'),
        (7, 'sess_tok_07a8b9c0d1', TIMESTAMP '2026-05-06 17:10:00', TIMESTAMP '2026-05-03 11:10:00'),
        (8, 'sess_tok_08b9c0d1e2', TIMESTAMP '2026-05-04 12:00:00', TIMESTAMP '2026-05-01 12:00:00'),
        (9, 'sess_tok_09c0d1e2f3', TIMESTAMP '2026-05-10 13:15:00', TIMESTAMP '2026-05-03 13:15:00'),
        (10, 'sess_tok_10d1e2f3g4', TIMESTAMP '2026-05-10 15:40:00', TIMESTAMP '2026-05-03 15:40:00')
)
INSERT INTO sessions (user_id, session_token, expires_at, created_at)
SELECT
    s.user_id,
    s.session_token,
    s.expires_at,
    COALESCE(s.created_at, CASE WHEN s.user_id = 4 THEN c.campaign_started_at ELSE c.default_token_created_at END)
FROM seed_sessions s
CROSS JOIN seed_constants c;

-- Insert Seed Data into `user_activities` table
WITH seed_activities (user_id, activity_type, activity_data, created_at) AS (
    VALUES
        (1, NULL, '{"ip": "192.168.1.5", "device": "Chrome/Mac", "location": "Madrid, Spain"}'::jsonb, TIMESTAMP '2026-05-03 10:05:00'),
        (2, 'profile_update', '{"fields_changed": ["theme", "bio"], "source": "web"}'::jsonb, TIMESTAMP '2026-05-03 12:15:00'),
        (3, 'password_reset_request', '{"ip": "10.0.0.4", "source": "mobile"}'::jsonb, TIMESTAMP '2026-05-03 14:10:00'),
        (4, 'account_creation', '{"signup_method": "email", "campaign": "google_ads"}'::jsonb, NULL),
        (5, NULL, '{"ip": "192.168.1.12", "device": "Firefox/Windows", "location": "Paris, France"}'::jsonb, TIMESTAMP '2026-05-03 10:22:00'),
        (6, 'email_verified', '{"verify_token": "abc123xyz_verify_token_6"}'::jsonb, TIMESTAMP '2026-05-02 09:05:00'),
        (7, NULL, '{"ip": "172.16.0.21", "device": "Safari/iPhone", "location": "Berlin, Germany"}'::jsonb, TIMESTAMP '2026-05-03 11:12:00'),
        (8, 'settings_change', '{"notifications": false, "source": "web"}'::jsonb, TIMESTAMP '2026-05-02 14:00:00'),
        (9, NULL, '{"ip": "192.168.1.42", "device": "Chrome/Mac", "location": "London, UK"}'::jsonb, TIMESTAMP '2026-05-03 13:18:00'),
        (10, NULL, '{"ip": "10.0.0.18", "device": "Safari/Mac", "location": "New York, USA"}'::jsonb, TIMESTAMP '2026-05-03 15:45:00')
)
INSERT INTO user_activities (user_id, activity_type, activity_data, created_at)
SELECT
    a.user_id,
    COALESCE(a.activity_type, c.user_login_activity),
    a.activity_data,
    COALESCE(a.created_at, c.campaign_started_at)
FROM seed_activities a
CROSS JOIN seed_constants c;

DROP TABLE seed_constants;