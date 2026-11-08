"""
UT4 - Health Endpoint Monitoring.

  /health/live   el proceso responde (no mira dependencias). Lo usa Docker.
  /health/ready  verifica que el broker este listo: es lo unico que ingreso
                 necesita para recibir paquetes. Lo usa el monitor.
"""

import socket
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FuturesTimeout

from fastapi import APIRouter
from fastapi.responses import JSONResponse

from app.cola import verificar_broker
from app.config import TIMEOUT_SALUD_S

INSTANCIA = socket.gethostname()

router = APIRouter(prefix="/health", tags=["salud"])


PLAZO_S = TIMEOUT_SALUD_S + 1


# Dependencias que verifica /health/ready.
CHEQUEOS = {
    "rabbitmq": verificar_broker,
}

_hilos = ThreadPoolExecutor(max_workers=4)


def _medir(chequeo):
    # Plazo duro: el timeout del cliente no cubre la resolucion DNS.
    inicio = time.perf_counter()
    try:
        _hilos.submit(chequeo).result(timeout=PLAZO_S)
        resultado = {"ok": True}
    except FuturesTimeout:
        resultado = {"ok": False, "error": f"sin respuesta en {PLAZO_S:g} s"}
    except Exception as error:
        # Algunos errores de pika vienen sin mensaje.
        resultado = {"ok": False, "error": str(error).strip() or type(error).__name__}
    resultado["ms"] = round((time.perf_counter() - inicio) * 1000, 1)
    return resultado


@router.get("/live")
def vivo():
    return {"estado": "ok", "componente": "ingreso", "instancia": INSTANCIA}


@router.get("/ready")
def listo():
    chequeos = {nombre: _medir(chequeo) for nombre, chequeo in CHEQUEOS.items()}
    sano = all(c["ok"] for c in chequeos.values())
    return JSONResponse(
        status_code=200 if sano else 503,
        content={
            "estado": "ok" if sano else "degradado",
            "componente": "ingreso",
            "instancia": INSTANCIA,
            "chequeos": chequeos,
        },
    )
