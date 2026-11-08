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
)


def crear_tabla():
    with motor.begin() as conexion:
        conexion.execute(text("""
            CREATE TABLE IF NOT EXISTS seguimiento_solicitud (
                id            UUID        PRIMARY KEY,
                estado        TEXT        NOT NULL,
                codigo_http   INTEGER     NOT NULL,
                resultado     JSONB       NOT NULL,
                procesada_en  TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """))


def guardar(solicitud_id, estado, codigo_http, resultado):
    """El ON CONFLICT hace que un evento duplicado no cambie nada."""
    with motor.begin() as conexion:
        conexion.execute(text("""
            INSERT INTO seguimiento_solicitud (id, estado, codigo_http, resultado)
            VALUES (:id, :estado, :codigo_http, CAST(:resultado AS JSONB))
            ON CONFLICT (id) DO NOTHING
        """), {"id": solicitud_id, "estado": estado, "codigo_http": codigo_http,
               "resultado": json.dumps(resultado)})


def obtener(solicitud_id):
    with motor.connect() as conexion:
        return conexion.execute(text("""
            SELECT estado, codigo_http, resultado, procesada_en
            FROM seguimiento_solicitud WHERE id = :id
        """), {"id": solicitud_id}).first()


def chequear():
    with motor.connect() as conexion:
        conexion.execute(text("SELECT 1"))
