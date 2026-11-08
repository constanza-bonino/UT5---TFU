"""Operaciones de dominio compartidas por la API y el consumidor de cola."""

from decimal import Decimal

from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.db import INSTANCIA, repo, vista_cinta


def ejecutar_admision(sesion: Session, cinta_id: str, tipo_paquete: str,
                      peso_kg: Decimal) -> dict:
    """Reserva cupo dentro de la transaccion activa de quien llama."""
    cinta = repo.obtener_para_actualizar(sesion, cinta_id)
    if cinta is None:
        raise HTTPException(404, f"cinta {cinta_id} no existe")

    disponible = cinta.capacidad_kg - cinta.carga_kg
    if peso_kg > disponible:
        raise HTTPException(409, {
            "motivo": "cupo insuficiente en la cinta",
            "cinta_id": cinta_id,
            "peso_solicitado_kg": float(peso_kg),
            "disponible_kg": float(disponible),
            "capacidad_kg": float(cinta.capacidad_kg),
            "carga_kg": float(cinta.carga_kg),
        })

    paquete_id = repo.registrar_admision(sesion, cinta, tipo_paquete, peso_kg)
    sesion.flush()
    return {
        "paquete_id": str(paquete_id),
        "cinta": vista_cinta(cinta),
        "instancia": INSTANCIA,
    }