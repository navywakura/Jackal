-- =============================================================================
-- Jackal — 0001: keyspace
--
-- Escritor exclusivo: servicio Phoenix (Elixir). Flask NO escribe en Scylla.
--
-- NetworkTopologyStrategy incluso con un solo DC: cambiar de SimpleStrategy a
-- NTS más adelante obliga a un repair completo del clúster. Empezar con NTS
-- cuesta cero hoy y convierte "añadir una región" en una operación de
-- infraestructura en lugar de una migración de datos.
--
-- El factor de replicación se sustituye en tiempo de despliegue:
--   desarrollo (nodo único) → 1
--   producción             → 3, con lecturas y escrituras a LOCAL_QUORUM
--
-- ./tools/migrate-scylla.sh sustituye ${SCYLLA_*} desde el entorno.
-- =============================================================================

CREATE KEYSPACE IF NOT EXISTS ${SCYLLA_KEYSPACE}
WITH replication = {
    'class': 'NetworkTopologyStrategy',
    '${SCYLLA_LOCAL_DC}': ${SCYLLA_REPLICATION_FACTOR}
}
AND durable_writes = true;
