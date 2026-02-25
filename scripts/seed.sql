DROP TABLE IF EXISTS users;
CREATE TABLE users (
    id   SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'guest'
);
INSERT INTO users (name, role) VALUES ('Alice', 'admin'), ('Bob', 'guest');
