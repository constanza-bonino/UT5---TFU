"""
UT4 - Gateway Offloading (patron de seguridad).

El componente ingreso, actuando como API Gateway / frontera publica, asume
la responsabilidad de autenticar a los clientes externos y validar sus
credenciales (API Keys).

Beneficios de Gateway Offloading:
  1. Centralizacion: la logica de autenticacion de clientes no se duplica en
     los servicios internos como admision.
  2. Reduccion de superficie de ataque: clientes no autenticados o con
     credenciales invalidas son rechazados en la frontera (HTTP 401) antes de
     que la solicitud llegue al backend.
  3. Desacoplamiento: admision se concentra exclusivamente en la gestion
     transaccional del cupo y no en administrar identidades externas.
"""

from fastapi import Header, HTTPException

from app.config import API_KEYS_VALIDAS, ENFORCE_API_KEY


def autenticar_cliente(x_api_key: str | None = Header(default=None)) -> str:
    """
    Verifica la API Key provista por el cliente externo en la cabecera X-API-Key.

    Si se envia una clave:
      - Si es valida (esta en API_KEYS_VALIDAS), autoriza la solicitud.
      - Si es invalida, rechaza inmediatamente con HTTP 401.

    Si no se envia una clave:
      - Si ENFORCE_API_KEY esta activado, exige autenticacion obligatoria (HTTP 401).
      - Si no esta activado, permite acceso en modo retrocompatible (anonimo).
    """
    if x_api_key is not None:
        if x_api_key in API_KEYS_VALIDAS:
            return x_api_key
        raise HTTPException(
            status_code=401,
            detail={
                "error": "no autorizado",
                "motivo": "API Key de cliente invalida en Gateway",
                "patron": "Gateway Offloading",
            },
        )

    if ENFORCE_API_KEY:
        raise HTTPException(
            status_code=401,
            detail={
                "error": "no autorizado",
                "motivo": "se requiere cabecera X-API-Key para acceder a este servicio",
                "patron": "Gateway Offloading",
            },
        )

    return "anonimo"
