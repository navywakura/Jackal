-- =============================================================================
-- Jackal — 0001: extensiones, utilidades e identidad
--
-- Escritor exclusivo: servicio Flask.
-- El servicio Phoenix accede con el rol jackal_ro (SOLO LECTURA).
-- =============================================================================

BEGIN;

-- gen_random_uuid() y digest(); citext para username/email sin sensibilidad a
-- mayúsculas. Ambas son extensiones contrib estándar, disponibles en RDS/Cloud SQL.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- -----------------------------------------------------------------------------
-- Utilidad: mantener updated_at sin depender de que la aplicación lo recuerde.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_updated_at() IS
    'Trigger BEFORE UPDATE: refresca updated_at a now().';

-- -----------------------------------------------------------------------------
-- users
--
-- La presencia en tiempo real (online/idle/dnd) NO vive aquí: la gestiona
-- Phoenix.Presence en memoria. last_seen_at es un mejor-esfuerzo que Flask
-- refresca de forma perezosa, útil solo para mostrar "visto hace 3 días"
-- cuando el usuario está desconectado.
-- -----------------------------------------------------------------------------
CREATE TABLE users (
    id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    username            citext      NOT NULL,
    email               citext      NOT NULL,
    password_hash       text        NOT NULL,

    display_name        text        NOT NULL DEFAULT '',
    avatar_url          text,
    bio                 text        NOT NULL DEFAULT '',
    status_message      text        NOT NULL DEFAULT '',
    locale              text        NOT NULL DEFAULT 'es',

    -- Se incrementa en cada cambio de rol/membresía del usuario. Phoenix la
    -- compara con la del JWT para detectar cachés de autorización obsoletas
    -- sin tener que revocar el token.
    permissions_version integer     NOT NULL DEFAULT 1,

    email_verified_at   timestamptz,
    last_seen_at        timestamptz,
    is_active           boolean     NOT NULL DEFAULT true,
    is_system           boolean     NOT NULL DEFAULT false,

    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    deleted_at          timestamptz,

    CONSTRAINT users_username_format   CHECK (username OPERATOR(pg_catalog.~) '^[A-Za-z0-9_.]{3,32}$'),
    CONSTRAINT users_email_format      CHECK (position('@' in email) > 1),
    CONSTRAINT users_bio_len           CHECK (length(bio) <= 300),
    CONSTRAINT users_status_len        CHECK (length(status_message) <= 128),
    CONSTRAINT users_display_name_len  CHECK (length(display_name) <= 64)
);

-- Índices únicos parciales: liberan el username/email al borrar en blando.
CREATE UNIQUE INDEX users_username_key ON users (username) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX users_email_key    ON users (email)    WHERE deleted_at IS NULL;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  users IS 'Identidad canónica. Escrito solo por Flask.';
COMMENT ON COLUMN users.password_hash IS
    'Argon2id codificado en PHC string format ($argon2id$v=19$m=65536,t=3,p=4$...).';
COMMENT ON COLUMN users.permissions_version IS
    'Contador de invalidación de caché de autorización. Ver docs/fase-1/04.';

-- -----------------------------------------------------------------------------
-- user_devices
--
-- Cada instalación de navegador es un "dispositivo" con su propio par de claves.
-- El material privado NUNCA llega al servidor: se cifra en el cliente con una
-- clave derivada de la contraseña (Argon2id) y se guarda en IndexedDB.
-- -----------------------------------------------------------------------------
CREATE TABLE user_devices (
    id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    name            text        NOT NULL DEFAULT 'Dispositivo',
    platform        text        NOT NULL DEFAULT 'web',
    user_agent      text,

    last_ip         inet,
    last_seen_at    timestamptz,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    revoked_at      timestamptz,
    revoked_reason  text,

    CONSTRAINT user_devices_name_len CHECK (length(name) BETWEEN 1 AND 64),
    CONSTRAINT user_devices_platform CHECK (platform IN ('web', 'desktop', 'mobile'))
);

CREATE INDEX user_devices_user_active_idx
    ON user_devices (user_id)
    WHERE revoked_at IS NULL;

CREATE TRIGGER user_devices_set_updated_at
    BEFORE UPDATE ON user_devices
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE user_devices IS
    'Un dispositivo = un juego de claves PQC. Revocarlo lo excluye de futuras épocas de clave.';

-- -----------------------------------------------------------------------------
-- refresh_tokens
--
-- Solo se guarda el SHA-256 del token. Una filtración de la tabla no permite
-- suplantar a nadie. Rotación: cada uso emite uno nuevo y marca el anterior
-- como usado, encadenándolos por replaced_by para detectar reutilización.
-- -----------------------------------------------------------------------------
CREATE TABLE refresh_tokens (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id    uuid        NOT NULL REFERENCES user_devices(id) ON DELETE CASCADE,

    token_sha256 bytea       NOT NULL,
    issued_at    timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    used_at      timestamptz,
    revoked_at   timestamptz,
    replaced_by  uuid        REFERENCES refresh_tokens(id) ON DELETE SET NULL,

    issued_ip    inet,

    CONSTRAINT refresh_tokens_sha_len CHECK (octet_length(token_sha256) = 32),
    CONSTRAINT refresh_tokens_ttl     CHECK (expires_at > issued_at)
);

CREATE UNIQUE INDEX refresh_tokens_hash_key ON refresh_tokens (token_sha256);
CREATE INDEX refresh_tokens_live_idx
    ON refresh_tokens (user_id, expires_at)
    WHERE revoked_at IS NULL AND used_at IS NULL;

COMMENT ON COLUMN refresh_tokens.replaced_by IS
    'Cadena de rotación. Si llega un token ya usado cuya cadena sigue viva, se '
    'asume robo y se revoca la familia entera.';

-- -----------------------------------------------------------------------------
-- jwt_signing_keys
--
-- Claves Ed25519 con las que Flask firma los JWT. La pública se publica en
-- /.well-known/jwks.json; Phoenix la cachea y verifica en local.
-- La privada NO se guarda aquí: se deriva de JWT_SIGNING_SEED_HEX (KMS en prod).
-- Esta tabla existe para que la rotación sea observable y solapada.
-- -----------------------------------------------------------------------------
CREATE TABLE jwt_signing_keys (
    kid            text        PRIMARY KEY,
    algorithm      text        NOT NULL DEFAULT 'EdDSA',
    public_key     bytea       NOT NULL,

    activated_at   timestamptz NOT NULL DEFAULT now(),
    -- Deja de firmar aquí, pero sigue publicándose en el JWKS hasta expires_at
    -- para que los tokens ya emitidos sigan validando.
    retires_at     timestamptz,
    expires_at     timestamptz NOT NULL,

    CONSTRAINT jwt_signing_keys_alg     CHECK (algorithm = 'EdDSA'),
    CONSTRAINT jwt_signing_keys_pub_len CHECK (octet_length(public_key) = 32),
    CONSTRAINT jwt_signing_keys_window  CHECK (expires_at > activated_at)
);

CREATE INDEX jwt_signing_keys_publishable_idx ON jwt_signing_keys (expires_at);

COMMENT ON TABLE jwt_signing_keys IS
    'Fuente de /.well-known/jwks.json. Ventana de solape retires_at→expires_at '
    'de al menos ACCESS_TOKEN_TTL para no invalidar tokens en vuelo.';

COMMIT;
