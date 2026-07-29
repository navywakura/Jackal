# ADR-0001: Separar el tiempo real (Elixir) de las APIs REST (Python)

- **Estado:** aceptada
- **Fecha:** 2026-07-29
- **Fase:** 1

## Contexto

El stack impuesto incluye Elixir/Phoenix y Python/Flask. Dos backends significan
dos despliegues, dos lenguajes y una frontera que hay que definir bien o se
convierte en la principal fuente de bugs del sistema. La decisión no es *si*
usar los dos, sino **dónde exactamente pasa la frontera** y qué la cruza.

## Decisión

La frontera se traza por **perfil de carga**, no por dominio funcional.

**Phoenix** se queda con todo lo que tiene una conexión abierta: Channels de
texto, señalización WebRTC, presencia, fan-out. Escribe en ScyllaDB.

**Flask** se queda con todo lo que es petición-respuesta: autenticación,
CRUD de servidores/canales/roles, directorio de claves PQC, adjuntos. Escribe
en PostgreSQL.

Reglas que hacen que la frontera funcione:

1. **Un único escritor por base de datos.** Flask nunca escribe en Scylla;
   Phoenix nunca escribe en Postgres. Elimina la necesidad de transacciones
   distribuidas.
2. **Phoenix lee Postgres directamente**, con un rol de solo lectura y grants
   por columna. No llama a Flask para autorizar.
3. **Flask no llama a Phoenix en el camino crítico.** Solo notificaciones
   best-effort (`/internal/*`) que, si fallan, se corrigen con el TTL de la
   caché.
4. **La ruta de un mensaje nunca toca Flask.** Ni una llamada HTTP.

## Alternativas consideradas

**Todo en Elixir.** Menos partes móviles y Phoenix sirve perfectamente APIs
REST. Descartada porque el stack está fijado y porque la lógica auxiliar
(criptografía con liboqs, procesamiento de adjuntos, integraciones) tiene un
ecosistema mucho más rico en Python.

**Todo en Python.** Flask con websockets aguantaría este volumen. Descartada
porque tira a la basura lo único que Elixir hace excepcionalmente bien —
presencia distribuida y fan-out con estado— y porque no hay un equivalente
razonable a `Phoenix.Presence` en Python sin montar Redis y resolver a mano los
conflictos de presencia entre nodos.

**Phoenix llama a Flask para autorizar.** Sería la separación más limpia:
Postgres solo lo tocaría su dueño. Descartada porque pone una llamada HTTP en
la ruta de cada `join`, y porque hace que un Flask caído tumbe también el chat.
El acoplamiento por esquema compartido es un precio menor que ese.

**Un único servicio con la base de datos compartida y sin reglas de escritura.**
Es lo que pasa por defecto cuando no se decide nada. Descartada explícitamente:
sin la regla de escritor único, la primera condición de carrera entre servicios
aparece la semana que se despliegan los dos.

## Consecuencias

**A favor**

- Fallos independientes: Flask caído no corta las conversaciones en curso.
- Cada servicio escala según su propio perfil (Phoenix por conexiones, Flask por
  peticiones).
- La ruta caliente no tiene ninguna dependencia de red fuera de Scylla.

**En contra**

- **Phoenix está acoplado al esquema de Postgres.** Una migración que renombre
  una columna que Phoenix lee lo rompe. Se mitiga con: la vista
  `member_server_permissions` como interfaz estable en vez de acceso directo a
  las tablas, grants explícitos por columna (una columna sin grant falla ruidosa
  y tempranamente), y la regla de que la FASE 2 solo consuma la vista y las
  tablas listadas en el `GRANT`.
- Dos lenguajes, dos toolchains, dos pipelines de CI.
- La lógica de permisos se implementa dos veces (Python y Elixir). El algoritmo
  está especificado en un único sitio —
  [02-modelo-de-datos.md §4](../fase-1/02-modelo-de-datos.md) — y ambas
  implementaciones deben pasar los mismos casos de prueba.

## Cuándo revisar esta decisión

Si el acoplamiento de esquema empieza a causar incidencias reales, el siguiente
paso es que Phoenix consulte una API interna de Flask con caché agresiva en ETS,
aceptando la latencia añadida solo en el `join` (no en cada mensaje).
