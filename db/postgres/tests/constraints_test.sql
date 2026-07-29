-- =============================================================================
-- Jackal — prueba de humo del esquema PostgreSQL
--
-- Verifica que las restricciones no triviales realmente rechazan lo que deben.
-- Cada bloque intenta una escritura inválida y falla la prueba si es ACEPTADA.
--
--   ./tools/migrate-postgres.sh test
--
-- Requiere el esquema aplicado; se ejecuta sobre una base de datos desechable
-- y hace ROLLBACK de todo al final.
-- =============================================================================

\set ON_ERROR_STOP on

BEGIN;

CREATE OR REPLACE FUNCTION assert_rejects(label text, stmt text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN others THEN
        RAISE NOTICE 'ok      %  (rechazado: %)', rpad(label, 46), left(SQLERRM, 60);
        RETURN;
    END;
    RAISE EXCEPTION 'FALLO: "%" fue ACEPTADO y debía rechazarse', label;
END;
$$;

CREATE OR REPLACE FUNCTION assert_accepts(label text, stmt text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE stmt;
    RAISE NOTICE 'ok      %  (aceptado)', rpad(label, 46);
END;
$$;

-- Datos de apoyo aislados de los del seed.
INSERT INTO users (id, username, email, password_hash) VALUES
    ('90000000-0000-4000-8000-000000000001', 'testuser1', 't1@test.local', 'x'),
    ('90000000-0000-4000-8000-000000000002', 'testuser2', 't2@test.local', 'x');

INSERT INTO servers (id, name, slug, owner_id) VALUES
    ('90000000-1000-4000-8000-000000000001', 'Servidor A', 'servidor-a',
     '90000000-0000-4000-8000-000000000001'),
    ('90000000-1000-4000-8000-000000000002', 'Servidor B', 'servidor-b',
     '90000000-0000-4000-8000-000000000001');

INSERT INTO roles (id, server_id, name, position, permissions, is_default) VALUES
    ('90000000-2000-4000-8000-000000000001', '90000000-1000-4000-8000-000000000001', '@everyone', 0, 3, true),
    ('90000000-2000-4000-8000-00000000000B', '90000000-1000-4000-8000-000000000002', '@everyone', 0, 3, true);

INSERT INTO server_members (server_id, user_id) VALUES
    ('90000000-1000-4000-8000-000000000001', '90000000-0000-4000-8000-000000000002');

INSERT INTO channels (id, server_id, name, kind, created_by) VALUES
    ('90000000-3000-4000-8000-000000000001', '90000000-1000-4000-8000-000000000001',
     'texto', 'text', '90000000-0000-4000-8000-000000000001');

INSERT INTO user_devices (id, user_id, name) VALUES
    ('90000000-4000-4000-8000-000000000001', '90000000-0000-4000-8000-000000000002', 'Portátil');

\echo ''
\echo '--- Identidad y perfil ---'
SELECT assert_rejects('username con caracteres ilegales',
    $$INSERT INTO users (username, email, password_hash)
      VALUES ('mal usuario!', 'x1@test.local', 'x')$$);
SELECT assert_rejects('username demasiado corto',
    $$INSERT INTO users (username, email, password_hash)
      VALUES ('ab', 'x2@test.local', 'x')$$);
SELECT assert_rejects('email duplicado ignorando mayúsculas (citext)',
    $$INSERT INTO users (username, email, password_hash)
      VALUES ('otro', 'T1@TEST.LOCAL', 'x')$$);
-- El índice único es PARCIAL (WHERE deleted_at IS NULL), así que borrar en
-- blando libera el username. Ojo: tienen que ser dos sentencias separadas —
-- un CTE «WITH d AS (UPDATE ...) INSERT ...» comparte snapshot y el índice
-- seguiría viendo la fila antigua.
UPDATE users SET deleted_at = now() WHERE username = 'testuser2';
SELECT assert_accepts('reutilizar username de usuario borrado en blando',
    $$INSERT INTO users (id, username, email, password_hash)
      VALUES ('90000000-0000-4000-8000-000000000099',
              'testuser2', 'nuevo@test.local', 'x')$$);
-- Revertir: los bloques siguientes usan testuser2 como miembro activo.
DELETE FROM users WHERE id = '90000000-0000-4000-8000-000000000099';
UPDATE users SET deleted_at = NULL WHERE id = '90000000-0000-4000-8000-000000000002';

\echo ''
\echo '--- Permisos ---'
SELECT assert_rejects('máscara de permisos con un bit no declarado',
    $$INSERT INTO roles (server_id, name, permissions)
      VALUES ('90000000-1000-4000-8000-000000000001', 'RolMalo', 1048576)$$);
SELECT assert_rejects('segundo rol @everyone en el mismo servidor',
    $$INSERT INTO roles (server_id, name, permissions, is_default)
      VALUES ('90000000-1000-4000-8000-000000000001', 'otro-everyone', 3, true)$$);
SELECT assert_rejects('rol por defecto fuera de position 0',
    $$INSERT INTO roles (server_id, name, permissions, is_default, position)
      VALUES ('90000000-1000-4000-8000-000000000002', 'ev2', 3, true, 5)$$);
SELECT assert_rejects('asignar a un miembro un rol de OTRO servidor',
    $$INSERT INTO member_roles (server_id, user_id, role_id)
      VALUES ('90000000-1000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002',
              '90000000-2000-4000-8000-00000000000B')$$);
SELECT assert_rejects('overwrite que permite y deniega el mismo bit',
    $$INSERT INTO channel_permission_overwrites (channel_id, role_id, allow_mask, deny_mask)
      VALUES ('90000000-3000-4000-8000-000000000001',
              '90000000-2000-4000-8000-000000000001', 6, 4)$$);
SELECT assert_rejects('overwrite dirigido a rol Y usuario a la vez',
    $$INSERT INTO channel_permission_overwrites (channel_id, role_id, user_id, allow_mask)
      VALUES ('90000000-3000-4000-8000-000000000001',
              '90000000-2000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002', 2)$$);
SELECT assert_rejects('overwrite sin ningún destinatario',
    $$INSERT INTO channel_permission_overwrites (channel_id, allow_mask)
      VALUES ('90000000-3000-4000-8000-000000000001', 2)$$);

\echo ''
\echo '--- Canales ---'
SELECT assert_rejects('canal de texto con bitrate de voz',
    $$INSERT INTO channels (server_id, name, kind, bitrate, user_limit)
      VALUES ('90000000-1000-4000-8000-000000000001', 'texto-malo', 'text', 32000, 8)$$);
SELECT assert_rejects('canal de voz sin bitrate',
    $$INSERT INTO channels (server_id, name, kind)
      VALUES ('90000000-1000-4000-8000-000000000001', 'voz-mala', 'voice')$$);
SELECT assert_rejects('canal de voz por encima del tope de la malla (8)',
    $$INSERT INTO channels (server_id, name, kind, bitrate, user_limit)
      VALUES ('90000000-1000-4000-8000-000000000001', 'voz-grande', 'voice', 32000, 20)$$);
SELECT assert_rejects('nombre de canal con mayúsculas',
    $$INSERT INTO channels (server_id, name, kind)
      VALUES ('90000000-1000-4000-8000-000000000001', 'General', 'text')$$);

\echo ''
\echo '--- Directorio de claves PQC ---'
-- Bundle con los tamaños correctos de FIPS 203/204.
SELECT assert_accepts('bundle de claves con tamaños correctos',
    $$INSERT INTO device_keys (id, device_id, user_id,
          x25519_public, ml_kem_public, ed25519_public, ml_dsa_public,
          bundle_signature, fingerprint)
      VALUES ('90000000-5000-4000-8000-000000000001',
              '90000000-4000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002',
              decode(repeat('00', 32), 'hex'),   decode(repeat('00', 1184), 'hex'),
              decode(repeat('01', 32), 'hex'),   decode(repeat('01', 1952), 'hex'),
              decode(repeat('02', 3373), 'hex'), decode(repeat('03', 32), 'hex'))$$);
SELECT assert_rejects('clave ML-KEM-768 con longitud incorrecta',
    $$INSERT INTO device_keys (device_id, user_id,
          x25519_public, ml_kem_public, ed25519_public, ml_dsa_public,
          bundle_signature, fingerprint)
      VALUES ('90000000-4000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002',
              decode(repeat('00', 32), 'hex'),   decode(repeat('00', 1183), 'hex'),
              decode(repeat('01', 32), 'hex'),   decode(repeat('01', 1952), 'hex'),
              decode(repeat('02', 3373), 'hex'), decode(repeat('04', 32), 'hex'))$$);
SELECT assert_rejects('segundo bundle activo para el mismo dispositivo',
    $$INSERT INTO device_keys (device_id, user_id, key_version,
          x25519_public, ml_kem_public, ed25519_public, ml_dsa_public,
          bundle_signature, fingerprint)
      VALUES ('90000000-4000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002', 2,
              decode(repeat('00', 32), 'hex'),   decode(repeat('00', 1184), 'hex'),
              decode(repeat('01', 32), 'hex'),   decode(repeat('01', 1952), 'hex'),
              decode(repeat('02', 3373), 'hex'), decode(repeat('05', 32), 'hex'))$$);

INSERT INTO channel_key_epochs (channel_id, epoch, reason, hkdf_salt, cek_commitment)
VALUES ('90000000-3000-4000-8000-000000000001', 0, 'init',
        decode(repeat('06', 32), 'hex'), decode(repeat('07', 32), 'hex'));

SELECT assert_accepts('share de CEK bien formado',
    $$INSERT INTO channel_key_shares (channel_id, epoch, recipient_device_id, recipient_key_id,
          ml_kem_ciphertext, x25519_ephemeral_public, wrapped_cek, wrap_nonce, sender_signature)
      VALUES ('90000000-3000-4000-8000-000000000001', 0,
              '90000000-4000-4000-8000-000000000001',
              '90000000-5000-4000-8000-000000000001',
              decode(repeat('08', 1088), 'hex'), decode(repeat('09', 32), 'hex'),
              decode(repeat('0a', 48), 'hex'),   decode(repeat('0b', 24), 'hex'),
              decode(repeat('0c', 3373), 'hex'))$$);
SELECT assert_rejects('share para una época que no existe',
    $$INSERT INTO channel_key_shares (channel_id, epoch, recipient_device_id, recipient_key_id,
          ml_kem_ciphertext, x25519_ephemeral_public, wrapped_cek, wrap_nonce, sender_signature)
      VALUES ('90000000-3000-4000-8000-000000000001', 99,
              '90000000-4000-4000-8000-000000000001',
              '90000000-5000-4000-8000-000000000001',
              decode(repeat('08', 1088), 'hex'), decode(repeat('09', 32), 'hex'),
              decode(repeat('0a', 48), 'hex'),   decode(repeat('0b', 24), 'hex'),
              decode(repeat('0c', 3373), 'hex'))$$);
-- Un segundo dispositivo, de otro usuario, para el caso cruzado.
INSERT INTO user_devices (id, user_id, name) VALUES
    ('90000000-4000-4000-8000-000000000002',
     '90000000-0000-4000-8000-000000000001', 'Sobremesa');

SELECT assert_rejects('share cuya clave no pertenece al dispositivo destinatario',
    $$INSERT INTO channel_key_shares (channel_id, epoch, recipient_device_id, recipient_key_id,
          ml_kem_ciphertext, x25519_ephemeral_public, wrapped_cek, wrap_nonce, sender_signature)
      VALUES ('90000000-3000-4000-8000-000000000001', 0,
              '90000000-4000-4000-8000-000000000002',
              '90000000-5000-4000-8000-000000000001',
              decode(repeat('08', 1088), 'hex'), decode(repeat('09', 32), 'hex'),
              decode(repeat('0a', 48), 'hex'),   decode(repeat('0b', 24), 'hex'),
              decode(repeat('0c', 3373), 'hex'))$$);

-- Época 1 aparte, para que el rechazo venga del trigger de revocación y no de
-- una colisión de clave primaria con el share de la época 0 ya insertado.
INSERT INTO channel_key_epochs (channel_id, epoch, reason, hkdf_salt, cek_commitment)
VALUES ('90000000-3000-4000-8000-000000000001', 1, 'device_revoked',
        decode(repeat('06', 32), 'hex'), decode(repeat('17', 32), 'hex'));
UPDATE device_keys SET revoked_at = now()
 WHERE id = '90000000-5000-4000-8000-000000000001';

SELECT assert_rejects('envolver una CEK contra una clave revocada',
    $$INSERT INTO channel_key_shares (channel_id, epoch, recipient_device_id, recipient_key_id,
          ml_kem_ciphertext, x25519_ephemeral_public, wrapped_cek, wrap_nonce, sender_signature)
      VALUES ('90000000-3000-4000-8000-000000000001', 1,
              '90000000-4000-4000-8000-000000000001',
              '90000000-5000-4000-8000-000000000001',
              decode(repeat('08', 1088), 'hex'), decode(repeat('09', 32), 'hex'),
              decode(repeat('0a', 48), 'hex'),   decode(repeat('0b', 24), 'hex'),
              decode(repeat('0c', 3373), 'hex'))$$);

\echo ''
\echo '--- Adjuntos ---'
SELECT assert_rejects('adjunto ready sin message_id',
    $$INSERT INTO attachments (channel_id, uploader_id, storage_key, byte_size,
          filename_ciphertext, filename_nonce, key_epoch, ciphertext_sha256, state)
      VALUES ('90000000-3000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002',
              'k/1', 10, '\x00'::bytea, decode(repeat('0d', 24), 'hex'), 0,
              decode(repeat('0e', 32), 'hex'), 'ready')$$);
SELECT assert_rejects('adjunto por encima de 100 MiB',
    $$INSERT INTO attachments (channel_id, uploader_id, storage_key, byte_size,
          filename_ciphertext, filename_nonce, key_epoch, ciphertext_sha256)
      VALUES ('90000000-3000-4000-8000-000000000001',
              '90000000-0000-4000-8000-000000000002',
              'k/2', 104857601, '\x00'::bytea, decode(repeat('0d', 24), 'hex'), 0,
              decode(repeat('0e', 32), 'hex'))$$);

\echo ''
\echo '--- Cascadas ---'
DELETE FROM channels WHERE id = '90000000-3000-4000-8000-000000000001';
DO $$
DECLARE n integer;
BEGIN
    SELECT count(*) INTO n FROM channel_key_shares
     WHERE channel_id = '90000000-3000-4000-8000-000000000001';
    IF n <> 0 THEN
        RAISE EXCEPTION 'FALLO: borrar el canal dejó % shares huérfanos', n;
    END IF;
    RAISE NOTICE 'ok      %  (0 shares huérfanos)',
                 rpad('borrar canal cascadea a épocas y shares', 46);
END;
$$;

\echo ''
\echo 'Todas las comprobaciones pasaron.'

ROLLBACK;
