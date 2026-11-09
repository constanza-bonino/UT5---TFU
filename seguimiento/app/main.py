"""
Componente seguimiento.

Arma una vista del estado de cada solicitud a partir de los eventos: la registra
como pendiente con paquete.recibido y la cierra con paquete.admitido o
paquete.rechazado. Puede ir atrasada, pero nunca adelantada: solo dice
"admitida" cuando llego paquete.admitido, que se publica despues del commit en
admision. Solo ese estado autoriza la entrada del paquete.
"""

import asyncio
import logging
import socket
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from sqlalchemy.exc import DBAPIError

from app import consumidor, vista
from app.config import MARGEN_VENCIDA_S

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


def _vencida(fila):
    return (fila.estado == "pendiente" and fila.vence_en is not None
            and datetime.now(timezone.utc) > fila.vence_en + timedelta(seconds=MARGEN_VENCIDA_S))


@app.get("/solicitudes/{solicitud_id}")
def consultar_solicitud(solicitud_id: uuid.UUID):
    """Devuelve 202 mientras esta pendiente, o el resultado final.

    Si una solicitud se perdio en el camino (por ejemplo, termino en una cola
    de fallidos) no queda pendiente para siempre: pasado su plazo se informa
    como vencida, igual que la rechazaria admision.
    """
    try:
        fila = vista.obtener(solicitud_id)
    except DBAPIError as error:
        return JSONResponse(status_code=503, content={
            "detail": f"base no disponible, reintente: {str(error).strip().splitlines()[0]}"})
    if fila is None or (fila.estado == "pendiente" and not _vencida(fila)):
        contenido = {"solicitud_id": str(solicitud_id), "estado": "pendiente"}
        if fila is not None and fila.vence_en is not None:
            contenido["vence_en"] = fila.vence_en.isoformat()
        return JSONResponse(status_code=202, content=contenido)

    if _vencida(fila):
        return {
            "solicitud_id": str(solicitud_id),
            "estado": "vencida",
            "codigo_resultado": 410,
            "resultado": {"detail": "la solicitud no se resolvio dentro de su plazo"},
            "vence_en": fila.vence_en.isoformat(),
        }

    return {
        "solicitud_id": str(solicitud_id),
        "estado": fila.estado,
        "codigo_resultado": fila.codigo_http,
        "resultado": fila.resultado,
        "procesada_en": fila.procesada_en.isoformat(),
    }
