-- =============================================================================
-- Jackal — datos de desarrollo. NO EJECUTAR EN PRODUCCIÓN.
--
-- Crea un servidor con dos roles (Admin, Miembro), tres canales y tres usuarios.
-- Los hashes de contraseña son marcadores: no corresponden a ninguna contraseña
-- real, así que no se puede iniciar sesión con estas cuentas hasta que Flask
-- (FASE 3) las regenere. Es deliberado: un seed no debe crear credenciales
-- utilizables.
--
-- El material criptográfico es relleno del tamaño correcto, no claves válidas.
-- Los bundles reales los genera el cliente en la FASE 4.
-- =============================================================================

BEGIN;

-- Identificadores fijos para poder referenciarlos desde tests y desde el cliente.
\set srv    '''11111111-1111-4111-8111-111111111111'''
\set u_ana  '''22222222-2222-4222-8222-222222222222'''
\set u_beto '''33333333-3333-4333-8333-333333333333'''
\set u_caro '''44444444-4444-4444-8444-444444444444'''

INSERT INTO users (id, username, email, password_hash, display_name, bio) VALUES
    (:u_ana::uuid,  'ana',  'ana@jackal.local',  '$argon2id$PLACEHOLDER$no-login', 'Ana',  'Fundadora del grupo'),
    (:u_beto::uuid, 'beto', 'beto@jackal.local', '$argon2id$PLACEHOLDER$no-login', 'Beto', ''),
    (:u_caro::uuid, 'caro', 'caro@jackal.local', '$argon2id$PLACEHOLDER$no-login', 'Caro', '')
ON CONFLICT DO NOTHING;

INSERT INTO servers (id, name, slug, description, owner_id) VALUES
    (:srv::uuid, 'Jackal Dev', 'jackal-dev', 'Servidor de pruebas de desarrollo', :u_ana::uuid)
ON CONFLICT DO NOTHING;

-- @everyone: ver, escribir, adjuntar, voz, vídeo, invitar.
--   VIEW_CHANNEL(1) | SEND_MESSAGES(2) | ATTACH_FILES(4) | CONNECT_VOICE(6)
--   | SPEAK(7) | VIDEO(8) | CREATE_INVITE(14)
--   = 2 + 4 + 16 + 64 + 128 + 256 + 16384 = 16854
INSERT INTO roles (id, server_id, name, position, permissions, is_default, color) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000001'::uuid, :srv::uuid, '@everyone', 0, 16854, true, 0)
ON CONFLICT DO NOTHING;

-- Admin: solo el bit ADMINISTRATOR, que implica todo lo demás.
INSERT INTO roles (id, server_id, name, position, permissions, is_hoisted, color) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000002'::uuid, :srv::uuid, 'Admin', 100, 1, true, 15158332)
ON CONFLICT DO NOTHING;

-- Moderador: gestionar mensajes, expulsar, silenciar en voz, rotar clave.
--   VIEW_CHANNEL(1)|SEND_MESSAGES(2)|MANAGE_MESSAGES(3)|ATTACH_FILES(4)
--   |CONNECT_VOICE(6)|SPEAK(7)|VIDEO(8)|MUTE_MEMBERS(9)|KICK_MEMBERS(12)
--   |CREATE_INVITE(14)|ROTATE_CHANNEL_KEY(16)
--   = 2+4+8+16+64+128+256+512+4096+16384+65536 = 87006
INSERT INTO roles (id, server_id, name, position, permissions, is_hoisted, color) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000003'::uuid, :srv::uuid, 'Moderador', 50, 87006, true, 3447003)
ON CONFLICT DO NOTHING;

INSERT INTO server_members (server_id, user_id, invited_by) VALUES
    (:srv::uuid, :u_ana::uuid,  NULL),
    (:srv::uuid, :u_beto::uuid, :u_ana::uuid),
    (:srv::uuid, :u_caro::uuid, :u_ana::uuid)
ON CONFLICT DO NOTHING;

INSERT INTO member_roles (server_id, user_id, role_id, assigned_by) VALUES
    (:srv::uuid, :u_ana::uuid,  'aaaaaaaa-0000-4000-8000-000000000002'::uuid, :u_ana::uuid),
    (:srv::uuid, :u_beto::uuid, 'aaaaaaaa-0000-4000-8000-000000000003'::uuid, :u_ana::uuid)
ON CONFLICT DO NOTHING;
-- Caro se queda solo con @everyone: es el caso "Miembro" del enunciado.

INSERT INTO channel_categories (id, server_id, name, position) VALUES
    ('cccccccc-0000-4000-8000-000000000001'::uuid, :srv::uuid, 'General', 0)
ON CONFLICT DO NOTHING;

INSERT INTO channels (id, server_id, category_id, name, kind, topic, position, created_by, bitrate, user_limit) VALUES
    ('cccccccc-1111-4000-8000-000000000001'::uuid, :srv::uuid,
     'cccccccc-0000-4000-8000-000000000001'::uuid,
     'general', 'text', 'Canal por defecto', 0, :u_ana::uuid, NULL, NULL),
    ('cccccccc-1111-4000-8000-000000000002'::uuid, :srv::uuid,
     'cccccccc-0000-4000-8000-000000000001'::uuid,
     'anuncios', 'text', 'Solo lectura para miembros', 1, :u_ana::uuid, NULL, NULL),
    ('cccccccc-1111-4000-8000-000000000003'::uuid, :srv::uuid,
     'cccccccc-0000-4000-8000-000000000001'::uuid,
     'sala-de-voz', 'voice', '', 2, :u_ana::uuid, 32000, 8)
ON CONFLICT DO NOTHING;

-- #anuncios: @everyone pierde SEND_MESSAGES (bit 2 → 4).
INSERT INTO channel_permission_overwrites (channel_id, role_id, allow_mask, deny_mask) VALUES
    ('cccccccc-1111-4000-8000-000000000002'::uuid,
     'aaaaaaaa-0000-4000-8000-000000000001'::uuid, 0, 4)
ON CONFLICT DO NOTHING;

INSERT INTO invites (code, server_id, channel_id, created_by, max_uses, expires_at) VALUES
    ('devinvite01', :srv::uuid, 'cccccccc-1111-4000-8000-000000000001'::uuid,
     :u_ana::uuid, 25, now() + interval '30 days')
ON CONFLICT DO NOTHING;

COMMIT;

\echo ''
\echo 'Seed aplicado. Permisos efectivos a nivel de servidor:'
SELECT u.username, p.is_owner, p.permissions
  FROM member_server_permissions p
  JOIN users u ON u.id = p.user_id
 ORDER BY u.username;
