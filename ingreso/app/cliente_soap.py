"""
Cliente SOAP de IAdmisionCinta (UT5 - migracion de REST a SOAP).

ingreso consulta el estado de la cinta con la operacion ConsultarCinta, que
reemplaza al GET /cintas/{cinta_id} de admision. zeep lee el contrato
(/soap?wsdl) la primera vez que se usa, arma los sobres XML y valida cada
respuesta contra el esquema del WSDL: si admision devolviera algo que no
cumple el contrato, la llamada falla aca y no llega al cliente.

Devuelve (codigo, cuerpo) igual que el cliente REST al que reemplaza.

La llamada pasa por un Circuit Breaker (circuito.py): si admision deja de
responder, despues de unos fallos ingreso corta en el acto en vez de esperar
el timeout en cada consulta.
"""

import asyncio
import logging

import httpx
from zeep import AsyncClient
from zeep.exceptions import Error as ErrorZeep
from zeep.exceptions import Fault
from zeep.helpers import serialize_object
from zeep.transports import AsyncTransport

from app.circuito import CircuitBreaker
from app.config import (ADMISION_WSDL, CIRCUITO_APERTURA_S,
                        CIRCUITO_UMBRAL_FALLOS, TIMEOUT_SOAP_S)

LOG = logging.getLogger("cliente_soap")

NS_ADM = "http://tfu.ucu.edu.uy/cinta/admision"

_cliente = None
_candado = asyncio.Lock()

circuito = CircuitBreaker("admision-soap", CIRCUITO_UMBRAL_FALLOS, CIRCUITO_APERTURA_S)


def _crear_cliente():
    # Bloqueante: descarga y procesa el WSDL. Se corre fuera del bucle de eventos.
    transporte = AsyncTransport(
        client=httpx.AsyncClient(timeout=TIMEOUT_SOAP_S),
        wsdl_client=httpx.Client(timeout=TIMEOUT_SOAP_S),
    )
    return AsyncClient(ADMISION_WSDL, transport=transporte)


async def _obtener_cliente():
    """Carga el contrato una sola vez. Si admision no responde, se reintenta
    en la proxima consulta en vez de dejar a ingreso sin arrancar."""
    global _cliente
    if _cliente is None:
        async with _candado:
            if _cliente is None:
                _cliente = await asyncio.to_thread(_crear_cliente)
                LOG.info("contrato SOAP de admision cargado de %s", ADMISION_WSDL)
    return _cliente


async def cerrar():
    global _cliente
    cliente, _cliente = _cliente, None
    if cliente is not None:
        await cliente.transport.aclose()


async def estado_cinta(cinta_id):
    """Invoca ConsultarCinta. Un Fault CintaInexistente se traduce a 404."""
    if not circuito.permitir():
        return 503, (f"admision no responde: circuito abierto, se reintenta en "
                     f"{circuito.segundos_para_reintentar()} s")

    resultado = None
    try:
        resultado = await _consultar(cinta_id)
        return resultado
    finally:
        # Si la llamada se cancela a mitad de camino (resultado None) tambien
        # cuenta como fallo, para no dejar la prueba del semiabierto colgada.
        if resultado is not None and resultado[0] in (200, 404):
            circuito.exito()
        else:
            circuito.fallo()


async def _consultar(cinta_id):
    try:
        cliente = await _obtener_cliente()
    except Exception as error:
        return 503, f"no se pudo obtener el contrato SOAP de admision: {error}"

    try:
        estado = await cliente.service.ConsultarCinta(cinta_id=cinta_id)
    except Fault as fault:
        if fault.detail is not None and fault.detail.find(f"{{{NS_ADM}}}CintaInexistente") is not None:
            return 404, fault.message
        return 503, f"admision respondio un SOAP Fault: {fault.message}"
    except (httpx.HTTPError, ErrorZeep) as error:
        return 503, f"no se pudo consultar a admision por SOAP: {error or type(error).__name__}"

    return 200, dict(serialize_object(estado))
