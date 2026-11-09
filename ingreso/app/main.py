"""
Componente ingreso. Es la frontera del sistema y el productor de eventos.

Recibe el paquete, publica paquete.recibido y responde 202. No valida el dominio
ni decide el cupo: eso lo hacen validacion y admision reaccionando a los eventos.
No guarda nada entre solicitudes, por eso se puede replicar.

El 202 significa "solicitud recibida". Solo el estado "admitida" de
GET /solicitudes/{id} autoriza la entrada del paquete a la cinta.

Los endpoints son asincronos y la publicacion AMQP (bloqueante por naturaleza
en pika) se deriva a un ejecutor acotado con asyncio.to_thread. Asi el bucle
de eventos sigue aceptando solicitudes aunque cientos de hilos esperen al
broker, y la sobrecarga se traduce en mas latencia en vez de conexiones caidas.
"""

import asyncio
import logging
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from app import cliente_admision
from app.cache import cache_cintas
from app.cola import iniciar_listener_cache, publicar
from app.config import (CACHE_HABILITADA, CACHE_TTL_S, CINTA_POR_DEFECTO,
                        HILOS_MAX, SOLICITUD_VIGENCIA_S)
from app.salud import INSTANCIA, vivo
from app.salud import router as router_salud
from app.seguridad import autenticar_cliente

LOG = logging.getLogger("ingreso")


@asynccontextmanager
async def ciclo_de_vida(_):
    bucle = asyncio.get_running_loop()
    bucle.set_default_executor(ThreadPoolExecutor(
        max_workers=HILOS_MAX, thread_name_prefix="ingreso-bloqueante"))
    iniciar_listener_cache(cache_cintas)
    yield
    await cliente_admision.cerrar()


app = FastAPI(
    title="Componente ingreso - API Cinta Transportadora",
    description="Interfaz IIngresoPaquetes. Productor de eventos del sistema.",
    version="3.0.0",
    lifespan=ciclo_de_vida,
)


class Paquete(BaseModel):
    tipo_paquete: str
    peso_kg: float
    alto_cm: float
    ancho_cm: float
    largo_cm: float
    cinta_id: str = CINTA_POR_DEFECTO


# UT4 - Health Endpoint Monitoring.
app.include_router(router_salud)


@app.get("/health")
def health():
    """Compatibilidad con la UT3. Equivale a /health/live."""
    return vivo()


@app.get("/")
def raiz():
    return health()


@app.get("/cache/metricas")
def metricas_cache():
    """Metricas de rendimiento del patron Cache-Aside."""
    return cache_cintas.metricas()


@app.post("/cintas/{cinta_id}/cache/invalidar")
def invalidar_cache_cinta(cinta_id: str):
    """Invalida explicitamente la cache de una cinta (Cache-Aside)."""
    invalidada = cache_cintas.invalidar(f"cinta:{cinta_id}")
    return {"cinta_id": cinta_id, "invalidada": invalidada}


@app.get("/cintas/{cinta_id}")
async def consultar_cinta(cinta_id: str):
    """
    Estado actual de la cinta. Es informativo: la cache puede estar atrasada y
    por eso nunca se usa para decidir si un paquete entra.
    Aplica el patron Cache-Aside (rendimiento):
    - Si el dato esta en cache (HIT), se devuelve sin consultar a admision.
    - Si no esta o expiro (MISS), se consulta a admision y se guarda en cache.
    """
    clave = f"cinta:{cinta_id}"
    if CACHE_HABILITADA:
        datos, hit = cache_cintas.obtener(clave)
        if hit:
            return JSONResponse(
                content={"cinta": datos, "instancia": {"ingreso": INSTANCIA, "cache": "hit"}},
                headers={"X-Cache": "HIT"},
            )

    codigo, cuerpo = await cliente_admision.estado_cinta(cinta_id)
    if codigo != 200:
        raise HTTPException(codigo, cuerpo)

    if CACHE_HABILITADA:
        cache_cintas.guardar(clave, cuerpo, CACHE_TTL_S)

    return JSONResponse(
        content={"cinta": cuerpo, "instancia": {"ingreso": INSTANCIA, "cache": "miss"}},
        headers={"X-Cache": "MISS"},
    )


@app.post("/paquetes", status_code=202)
async def recibir_paquete(
    paquete: Paquete,
    cliente_autenticado: str = Depends(autenticar_cliente),
):
    """Publica paquete.recibido. El resultado se consulta en /solicitudes/{id}.

    Si el broker no esta disponible se responde 503 (reintentable) en vez de
    dejar caer la conexion.
    """
    solicitud_id = str(uuid.uuid4())
    vence_en = datetime.now(timezone.utc) + timedelta(seconds=SOLICITUD_VIGENCIA_S)
    try:
        await asyncio.to_thread(publicar, "paquete.recibido", {
            **paquete.model_dump(),
            "solicitud_id": solicitud_id,
            "vence_en": vence_en.isoformat(),
        })
    except Exception as error:
        LOG.warning("publicacion de evento fallida: %s", error)
        raise HTTPException(503, f"broker no disponible, reintente: {error}")

    return JSONResponse(status_code=202, content={
        "solicitud_id": solicitud_id,
        "estado": "pendiente",
        "mensaje": "Solicitud recibida. El paquete solo puede entrar cuando este admitida.",
        "cliente": cliente_autenticado,
        "instancia": {"ingreso": INSTANCIA},
    })


@app.get("/solicitudes/{solicitud_id}")
async def consultar_solicitud(
    solicitud_id: uuid.UUID,
    _: str = Depends(autenticar_cliente),
):
    """Devuelve 202 mientras esta pendiente, o el resultado final."""
    codigo, cuerpo = await cliente_admision.estado_solicitud(solicitud_id)
    if codigo == 503:
        raise HTTPException(codigo, cuerpo)
    return JSONResponse(status_code=codigo, content=cuerpo)
