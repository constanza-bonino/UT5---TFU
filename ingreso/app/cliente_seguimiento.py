"""
Cliente HTTP de seguimiento, para consultar el estado de una solicitud.

Devuelve siempre (codigo, cuerpo) para que main.py decida que responder.

Usa un unico httpx.AsyncClient con conexiones persistentes (keep-alive). La
version anterior abria una conexion nueva con httpx.request por cada llamada
y corria en endpoints sincronos, asi que con cientos de solicitudes
concurrentes se agotaban los hilos del servidor antes que la cinta.
"""

import threading

import httpx

from app.config import CLAVE_INTERNA, SEGUIMIENTO_URL, TIMEOUT_ADMISION_S

_cliente = None
_candado = threading.Lock()


def _cliente_async():
    global _cliente
    if _cliente is None:
        with _candado:
            if _cliente is None:
                _cliente = httpx.AsyncClient(
                    timeout=TIMEOUT_ADMISION_S,
                    limits=httpx.Limits(
                        max_connections=200,
                        max_keepalive_connections=100,
                    ),
                )
    return _cliente


async def cerrar():
    """Cierra el cliente compartido al apagar el servicio."""
    global _cliente
    cliente, _cliente = _cliente, None
    if cliente is not None:
        await cliente.aclose()


async def _pedir(url):
    cabeceras = {"X-Clave-Interna": CLAVE_INTERNA}
    try:
        r = await _cliente_async().get(url, headers=cabeceras)
    except httpx.HTTPError as error:
        return 503, f"no se pudo contactar al componente interno: {error}"

    try:
        cuerpo = r.json()
    except Exception:
        # Puertas intermedias (nginx) o caidas pueden devolver texto plano.
        return r.status_code, (r.text or "")[:500]
    if r.status_code != 200:
        cuerpo = cuerpo.get("detail", cuerpo) if isinstance(cuerpo, dict) else cuerpo
    return r.status_code, cuerpo


async def estado_solicitud(solicitud_id):
    """Consulta si una solicitud sigue pendiente o ya termino."""
    return await _pedir(f"{SEGUIMIENTO_URL}/solicitudes/{solicitud_id}")
