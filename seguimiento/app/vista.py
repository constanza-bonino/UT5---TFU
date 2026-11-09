"""Vista de estado de las solicitudes. Este componente es el unico que la usa."""

import json

from sqlalchemy import create_engine, text

from app.config import DATABASE_URL, DB_POOL_SIZE, DB_POOL_TIMEOUT_S

motor = create_engine(
    DATABASE_URL,
    pool_pre_ping=True,
    pool_size=DB_POOL_SIZE,
    max_overflow=0,
    pool_timeout=DB_POOL_TIMEOUT_S,
    # Sin esto, con la base caida /health/ready se queda colgado y el monitor
    # lo ve SIN RESPUESTA en vez de DEGRADADO.
    connect_args={"connect_timeout": 2},
)


def crear_tabla():
    with motor.begin() as conexion:
        conexion.execute(text("""
            CREATE TABLE IF NOT EXISTS seguimiento_solicitud (
                id            UUID        PRIMARY KEY,
                estado        TEXT        NOT NULL,
                codigo_http   INTEGER,
                resultado     JSONB,
                vence_en      TIMESTAMPTZ,
                recibida_en   TIMESTAMPTZ,
                procesada_en  TIMESTAMPTZ
            )
        """))


def guardar_recibida(solicitud_id, vence_en):
    """Registra la solicitud como pendiente.

    Los eventos de una misma solicitud pueden procesarse en cualquier orden
    (hay varios consumidores), asi que si el resultado llego antes no se toca.
    """
    with motor.begin() as conexion:
        conexion.execute(text("""
            INSERT INTO seguimiento_solicitud (id, estado, vence_en, recibida_en)
            VALUES (:id, 'pendiente', :vence_en, now())
            ON CONFLICT (id) DO UPDATE
               SET vence_en = EXCLUDED.vence_en,
                   recibida_en = EXCLUDED.recibida_en
        """), {"id": solicitud_id, "vence_en": vence_en})


def guardar_resultado(solicitud_id, estado, codigo_http, resultado):
    """Guarda el resultado final. Un evento duplicado no cambia nada."""
    with motor.begin() as conexion:
        conexion.execute(text("""
            INSERT INTO seguimiento_solicitud (id, estado, codigo_http, resultado, procesada_en)
            VALUES (:id, :estado, :codigo_http, CAST(:resultado AS JSONB), now())
            ON CONFLICT (id) DO UPDATE
               SET estado = EXCLUDED.estado,
                   codigo_http = EXCLUDED.codigo_http,
                   resultado = EXCLUDED.resultado,
                   procesada_en = EXCLUDED.procesada_en
             WHERE seguimiento_solicitud.estado = 'pendiente'
        """), {"id": solicitud_id, "estado": estado, "codigo_http": codigo_http,
               "resultado": json.dumps(resultado)})


def obtener(solicitud_id):
    with motor.connect() as conexion:
        return conexion.execute(text("""
            SELECT estado, codigo_http, resultado, vence_en, recibida_en, procesada_en
            FROM seguimiento_solicitud WHERE id = :id
        """), {"id": solicitud_id}).first()


def chequear():
    with motor.connect() as conexion:
        conexion.execute(text("SELECT 1"))
