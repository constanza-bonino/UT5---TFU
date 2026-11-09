"""
Componente seguimiento.

Arma una vista del estado de cada solicitud a partir de los eventos finales.
Puede ir atrasada, pero nunca adelantada: solo dice "admitida" cuando llego
paquete.admitido, que se publica despues del commit en admision. Solo ese estado
autoriza la entrada del paquete.
"""

import asyncio
import logging
import socket
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from app import consumidor, vista

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

INSTANCIA = socket.gethostname()


@asynccontextmanager
async def ciclo_de_vida(_):
    # La base ya esta sana por el depends_on, pero puede tardar en aceptar conexiones.
    for intento in range(10):
        try:
            await asyncio.to_thread(vista.crear_tabla)
            break
        except Exception:
            if intento == 9:
                raise
            await asyncio.sleep(2)
    consumidor.iniciar()
    yield


app = FastAPI(title="Componente seguimiento", lifespan=ciclo_de_vida)


@app.get("/health/live")
def vivo():
    return {"estado": "ok", "componente": "seguimiento", "instancia": INSTANCIA}


@app.get("/health/ready")
def listo():
    try:
        vista.chequear()
    except Exception as error:
        return JSONResponse(status_code=503, content={
            "estado": "degradado", "componente": "seguimiento", "instancia": INSTANCIA,
            "chequeos": {"base": {"ok": False, "error": str(error).strip().splitlines()[0]}},
        })
    return {"estado": "ok", "componente": "seguimiento", "instancia": INSTANCIA,
            "chequeos": {"base": {"ok": True}}}


@app.get("/solicitudes/{solicitud_id}")
def consultar_solicitud(solicitud_id: uuid.UUID):
    """Devuelve 202 mientras no llego un resultado final."""
    fila = vista.obtener(solicitud_id)
    if fila is None:
        return JSONResponse(status_code=202, content={
            "solicitud_id": str(solicitud_id), "estado": "pendiente"})
    return {
        "solicitud_id": str(solicitud_id),
        "estado": fila.estado,
        "codigo_resultado": fila.codigo_http,
        "resultado": fila.resultado,
        "procesada_en": fila.procesada_en.isoformat(),
    }
