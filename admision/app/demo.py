"""
Endpoints usados solo por los scripts de demostracion. No son parte de la
interfaz IAdmisionCinta, y por eso van bajo el prefijo /demo.

Sirven para reiniciar el estado entre corridas y para poder mostrar, con
numeros y no solo con argumentos, que pasaria sin las garantias del sistema.
"""

import time
from decimal import Decimal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError

from app.config import CINTA_CAPACIDAD_KG, VENTANA_CARRERA_S
from app.db import INSTANCIA, Sesion, repo, vista_cinta
from app.modelos import Cinta, PaqueteEnTransito

router = APIRouter(prefix="/demo", tags=["demostraciones"])


class SolicitudAdmision(BaseModel):
    tipo_paquete: str
    peso_kg: float = Field(gt=0)


class SolicitudForzarCarga(BaseModel):
    carga_kg: float


class FalloInyectado(Exception):
    """Fallo provocado a proposito para demostrar atomicidad."""


def _contar_paquetes(sesion, cinta_id):
    return int(sesion.scalar(
        select(func.count()).select_from(PaqueteEnTransito)
        .where(PaqueteEnTransito.cinta_id == cinta_id)) or 0)


@router.post("/cintas/{cinta_id}/reiniciar")
def reiniciar(cinta_id: str):
    """Vacia la cinta y vuelve a aplicar la capacidad configurada."""
    with Sesion() as sesion:
        with sesion.begin():
            if repo.obtener_para_actualizar(sesion, cinta_id) is None:
                raise HTTPException(404, f"cinta {cinta_id} no existe")
            repo.reiniciar(sesion, cinta_id, Decimal(str(CINTA_CAPACIDAD_KG)))
        vista = vista_cinta(repo.obtener(sesion, cinta_id))

    return {"estado": "reiniciada", "cinta": vista, "instancia": INSTANCIA}


@router.post("/cintas/{cinta_id}/admision-con-fallo")
def admision_con_fallo(cinta_id: str, solicitud: SolicitudAdmision):
    """
    Atomicidad. Corre la misma transaccion que la admision real pero falla
    despues de escribir el paquete y actualizar la carga, antes del COMMIT.
    Si es atomica, la base tiene que quedar igual que antes.
    """
    peso = Decimal(str(solicitud.peso_kg))

    with Sesion() as sesion:
        cinta = repo.obtener(sesion, cinta_id)
        if cinta is None:
            raise HTTPException(404, f"cinta {cinta_id} no existe")
        antes = vista_cinta(cinta)
        paquetes_antes = _contar_paquetes(sesion, cinta_id)

    with Sesion() as sesion:
        try:
            with sesion.begin():
                cinta = repo.obtener_para_actualizar(sesion, cinta_id)
                repo.registrar_admision(sesion, cinta, solicitud.tipo_paquete, peso)
                sesion.flush()          # las dos escrituras ya fueron a la base
                raise FalloInyectado()  # y ahora el proceso falla
        except FalloInyectado:
            pass                        # el with ya hizo el ROLLBACK

    with Sesion() as sesion:
        despues = vista_cinta(repo.obtener(sesion, cinta_id))
        paquetes_despues = _contar_paquetes(sesion, cinta_id)

    return {
        "propiedad": "atomicidad",
        "antes": {"carga_kg": antes["carga_kg"], "paquetes": paquetes_antes},
        "despues": {"carga_kg": despues["carga_kg"], "paquetes": paquetes_despues},
        "sin_cambios": (antes["carga_kg"] == despues["carga_kg"]
                        and paquetes_antes == paquetes_despues),
        "instancia": INSTANCIA,
    }


@router.post("/cintas/{cinta_id}/forzar-carga")
def forzar_carga(cinta_id: str, solicitud: SolicitudForzarCarga):
    """
    Consistencia. Escribe un valor de carga directamente en la tabla, saltandose
    toda la logica del servicio. Si viola el invariante, la restriccion CHECK lo
    rechaza en la base.
    """
    valor = Decimal(str(solicitud.carga_kg))

    with Sesion() as sesion:
        try:
            with sesion.begin():
                resultado = sesion.execute(
                    update(Cinta).where(Cinta.id == cinta_id).values(carga_kg=valor))
                if resultado.rowcount == 0:
                    raise HTTPException(404, f"cinta {cinta_id} no existe")
        except IntegrityError as error:
            return {
                "propiedad": "consistencia",
                "resultado": "rechazado por la base de datos",
                "valor_intentado_kg": float(valor),
                "restriccion": "cupo_no_excedido",
                "error": str(error.orig).strip(),
                "instancia": INSTANCIA,
            }
        vista = vista_cinta(repo.obtener(sesion, cinta_id))

    return {"propiedad": "consistencia",
            "resultado": "aceptado (el valor respeta el invariante)",
            "valor_intentado_kg": float(valor), "cinta": vista,
            "instancia": INSTANCIA}


@router.get("/cintas/{cinta_id}/eventual")
def estado_eventual(cinta_id: str):
    """Estado del almacen que emula BASE."""
    with Sesion() as sesion:
        fila = repo.leer_eventual(sesion, cinta_id)
    if fila is None:
        raise HTTPException(404, f"cinta {cinta_id} no existe")

    carga, capacidad, peso_real, admitidos = fila
    return {
        "id": cinta_id,
        "capacidad_kg": float(capacidad),
        "carga_kg_segun_el_sistema": float(carga),
        "peso_kg_realmente_sobre_la_cinta": float(peso_real),
        "paquetes_admitidos": int(admitidos),
        "sobrecarga_kg": float(peso_real - capacidad),
        "instancia": INSTANCIA,
    }


@router.post("/cintas/{cinta_id}/admision-sin-transaccion")
def admision_sin_transaccion(cinta_id: str, solicitud: SolicitudAdmision):
    """
    Como se resolveria la admision sobre un almacen eventualmente consistente:
    se lee, se decide fuera de toda transaccion y despues se escribe. Sin
    bloqueo de fila y sin invariante en el esquema, bajo concurrencia todas las
    solicitudes leen "hay lugar" y todas entran.
    """
    peso = Decimal(str(solicitud.peso_kg))

    # 1. Leer. La transaccion se cierra aca, asi que el dato ya puede quedar viejo.
    with Sesion() as sesion:
        fila = repo.leer_eventual(sesion, cinta_id)
    if fila is None:
        raise HTTPException(404, f"cinta {cinta_id} no existe")
    carga, capacidad, _, _ = fila

    # 2. Ventana de propagacion, que es lo que tarda una escritura en verse
    #    desde otro nodo en un almacen eventualmente consistente.
    time.sleep(VENTANA_CARRERA_S)

    # 3. Decidir sobre esa lectura vieja.
    disponible = capacidad - carga
    if peso > disponible:
        raise HTTPException(409, {"motivo": "cupo insuficiente segun la lectura eventual",
                                  "disponible_kg": float(disponible)})

    # 4. Escribir pisando el valor calculado.
    with Sesion() as sesion:
        with sesion.begin():
            repo.escribir_eventual(sesion, cinta_id, carga + peso, peso)

    return {"estado": "aceptado",
            "advertencia": "camino sin transaccion, sin garantia de cupo",
            "carga_kg_escrita": float(carga + peso), "instancia": INSTANCIA}
