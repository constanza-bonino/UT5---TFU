"""
Componente admision. Administra el cupo de carga de la cinta, que es el recurso
compartido y finito del sistema.

La admision de paquetes ya no es un endpoint: la hace cola_worker.py al recibir
paquete.validado. Esta API solo consulta la cinta y registra egresos.

El servicio en si no guarda nada en memoria: todo el estado esta en PostgreSQL.
Por eso tambien se puede replicar, ya que dos replicas que compiten por la misma
cinta se serializan en la base y no en el proceso.

Los endpoints son asincronos y el trabajo de base (bloqueante con el driver
sincrono) se deriva a un ejecutor acotado. El bucle de eventos sigue respondiendo
(salud, lecturas) y una espera agotada devuelve 503 reintentable en vez de dejar
caer la conexion.
"""

import asyncio
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from sqlalchemy import func, select
from sqlalchemy.exc import DBAPIError

from app.config import HILOS_DB
from app.db import INSTANCIA, Sesion, repo, sembrar_cinta, vista_cinta
from app.demo import router as router_demo
from app.modelos import PaqueteEnTransito
from app.salud import router as router_salud
from app.salud import vivo


@asynccontextmanager
async def ciclo_de_vida(_):
    bucle = asyncio.get_running_loop()
    bucle.set_default_executor(ThreadPoolExecutor(
        max_workers=HILOS_DB, thread_name_prefix="admision-bloqueante"))
    # La base ya esta sana por el depends_on del compose, pero puede tardar unos
    # segundos mas en aceptar conexiones.
    for intento in range(10):
        try:
            await asyncio.to_thread(sembrar_cinta)
            break
        except Exception:
            if intento == 9:
                raise
            await asyncio.sleep(2)
    yield


app = FastAPI(
    title="Componente admision: cupo de cinta transportadora",
    description="Interfaz IAdmisionCinta. Consume IRepositorioCinta.",
    version="2.0.0",
    lifespan=ciclo_de_vida,
)


class SolicitudEgreso(BaseModel):
    paquete_id: uuid.UUID


# UT4 - Health Endpoint Monitoring.
app.include_router(router_salud)


@app.get("/health")
def health():
    """Compatibilidad con la UT3. Equivale a /health/live."""
    return vivo()


@app.get("/")
def raiz():
    return health()


def _consultar_en_hilo(cinta_id: str):
    with Sesion() as sesion:
        cinta = repo.obtener(sesion, cinta_id)
        if cinta is None:
            raise HTTPException(404, f"cinta {cinta_id} no existe")

        cantidad = sesion.scalar(
            select(func.count()).select_from(PaqueteEnTransito)
            .where(PaqueteEnTransito.cinta_id == cinta_id))
        vista = vista_cinta(cinta)

    vista["paquetes_en_transito"] = int(cantidad or 0)
    vista["instancia"] = INSTANCIA
    return vista


@app.get("/cintas/{cinta_id}")
async def consultar(cinta_id: str):
    """Estado actual de la cinta. Lectura sin bloqueo."""
    try:
        return await asyncio.to_thread(_consultar_en_hilo, cinta_id)
    except HTTPException:
        raise
    except DBAPIError as error:
        raise HTTPException(503, f"base no disponible, reintente: {error}")


def _egresar_en_hilo(cinta_id: str, paquete_id: uuid.UUID):
    with Sesion() as sesion:
        with sesion.begin():
            cinta = repo.obtener_para_actualizar(sesion, cinta_id)
            if cinta is None:
                raise HTTPException(404, f"cinta {cinta_id} no existe")

            peso = repo.registrar_egreso(sesion, cinta, paquete_id)
            if peso is None:
                raise HTTPException(
                    404, f"el paquete {paquete_id} no esta en la cinta")
            vista = vista_cinta(cinta)

    return {"estado": "egresado", "peso_liberado_kg": float(peso),
            "cinta": vista, "instancia": INSTANCIA}


@app.post("/cintas/{cinta_id}/egresos")
async def egresar(cinta_id: str, solicitud: SolicitudEgreso):
    """Un paquete sale de la cinta y libera su peso. Tambien es transaccional."""
    try:
        return await asyncio.to_thread(
            _egresar_en_hilo, cinta_id, solicitud.paquete_id)
    except HTTPException:
        raise
    except DBAPIError as error:
        raise HTTPException(503, f"base no disponible, reintente: {error}")


# Endpoints de las demostraciones. No son parte de IAdmisionCinta.
app.include_router(router_demo)
