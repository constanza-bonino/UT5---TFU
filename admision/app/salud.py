"""
UT4 - Health Endpoint Monitoring.

  /health/live   el proceso responde (no mira dependencias). Lo usa Docker.
  /health/ready  verifica las dependencias. Lo usa el monitor.
"""

import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout

from fastapi import APIRouter
from fastapi.responses import JSONResponse
from sqlalchemy import create_engine, text
from sqlalchemy.pool import NullPool

from app.config import DATABASE_URL, TIMEOUT_SALUD_S
from app.db import INSTANCIA

router = APIRouter(prefix="/health", tags=["salud"])

# Sin pool y con timeouts cortos: cada chequeo prueba una conexion nueva.
_motor_salud = create_engine(
    DATABASE_URL,
    poolclass=NullPool,
    connect_args={
        "connect_timeout": TIMEOUT_SALUD_S,
        "options": f"-c statement_timeout={TIMEOUT_SALUD_S * 1000}",
    },
)


def _chequear_base():
    with _motor_salud.connect() as conexion:
        conexion.execute(text("SELECT 1"))


# Dependencias que verifica /health/ready.
CHEQUEOS = {
    "base": _chequear_base,
}

_hilos = ThreadPoolExecutor(max_workers=4)


def _medir(chequeo):
    # Plazo duro: el timeout de conexion no cubre la resolucion DNS.
    inicio = time.perf_counter()
    try:
        _hilos.submit(chequeo).result(timeout=TIMEOUT_SALUD_S)
        resultado = {"ok": True}
    except FuturesTimeout:
        resultado = {"ok": False, "error": f"sin respuesta en {TIMEOUT_SALUD_S} s"}
    except Exception as error:
        resultado = {"ok": False, "error": str(error).strip().splitlines()[0]}
    resultado["ms"] = round((time.perf_counter() - inicio) * 1000, 1)
    return resultado


@router.get("/live")
def vivo():
    return {"estado": "ok", "componente": "admision", "instancia": INSTANCIA}


@router.get("/ready")
def listo():
    chequeos = {nombre: _medir(chequeo) for nombre, chequeo in CHEQUEOS.items()}
    sano = all(c["ok"] for c in chequeos.values())
    return JSONResponse(
        status_code=200 if sano else 503,
        content={
            "estado": "ok" if sano else "degradado",
            "componente": "admision",
            "instancia": INSTANCIA,
            "chequeos": chequeos,
        },
    )
