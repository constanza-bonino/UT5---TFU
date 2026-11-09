"""
UT5 - Migracion de REST a SOAP.

ConsultarCinta reemplaza a GET /cintas/{cinta_id}: es la misma consulta y
devuelve los mismos datos, pero con mensajes XML y un contrato WSDL
(contratos/admision.wsdl). El contrato se escribio primero y este modulo lo
implementa; ingreso lo consume con zeep, que valida cada respuesta contra el
esquema del WSDL.

  GET  /soap?wsdl   devuelve el contrato
  POST /soap        recibe un sobre SOAP 1.1 y responde otro sobre, o un Fault

No se uso spyne porque su ultima version no funciona con Python 3.12.
"""

import asyncio
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import Response
from lxml import etree
from sqlalchemy import func, select
from sqlalchemy.exc import DBAPIError

from app.db import INSTANCIA, Sesion, repo, vista_cinta
from app.modelos import PaqueteEnTransito

NS_SOAP = "http://schemas.xmlsoap.org/soap/envelope/"
NS_ADM = "http://tfu.ucu.edu.uy/cinta/admision"
TIPO_XML = "text/xml; charset=utf-8"

_WSDL = (Path(__file__).parent / "contratos" / "admision.wsdl").read_text(encoding="utf-8")

# El XML llega de afuera: sin entidades ni accesos a la red al parsearlo.
_PARSER = etree.XMLParser(resolve_entities=False, no_network=True, remove_blank_text=True)

# Mismo orden que la secuencia de EstadoCinta en el WSDL.
_CAMPOS = ("id", "capacidad_kg", "carga_kg", "disponible_kg", "paquetes_en_transito", "instancia")

router = APIRouter(tags=["soap"])


def _consultar_cinta(cinta_id):
    """Estado de la cinta, o None si no existe. Lectura sin bloqueo."""
    with Sesion() as sesion:
        cinta = repo.obtener(sesion, cinta_id)
        if cinta is None:
            return None
        cantidad = sesion.scalar(
            select(func.count()).select_from(PaqueteEnTransito)
            .where(PaqueteEnTransito.cinta_id == cinta_id))
        vista = vista_cinta(cinta)

    vista["paquetes_en_transito"] = int(cantidad or 0)
    vista["instancia"] = INSTANCIA
    return vista


def _sobre():
    sobre = etree.Element(etree.QName(NS_SOAP, "Envelope"), nsmap={"soapenv": NS_SOAP, "adm": NS_ADM})
    return sobre, etree.SubElement(sobre, etree.QName(NS_SOAP, "Body"))


def _xml(sobre, codigo_http):
    return Response(etree.tostring(sobre, xml_declaration=True, encoding="utf-8"),
                    status_code=codigo_http, media_type=TIPO_XML)


def _respuesta(estado):
    sobre, cuerpo = _sobre()
    respuesta = etree.SubElement(cuerpo, etree.QName(NS_ADM, "ConsultarCintaResponse"))
    nodo = etree.SubElement(respuesta, etree.QName(NS_ADM, "estado"))
    for campo in _CAMPOS:
        etree.SubElement(nodo, etree.QName(NS_ADM, campo)).text = str(estado[campo])
    return _xml(sobre, 200)


def _fault(codigo, mensaje, cinta_inexistente=None):
    """SOAP 1.1: un Fault viaja con HTTP 500. Client = error de quien llama."""
    sobre, cuerpo = _sobre()
    fault = etree.SubElement(cuerpo, etree.QName(NS_SOAP, "Fault"))
    etree.SubElement(fault, "faultcode").text = f"soapenv:{codigo}"
    etree.SubElement(fault, "faultstring").text = mensaje
    if cinta_inexistente is not None:
        detalle = etree.SubElement(fault, "detail")
        error = etree.SubElement(detalle, etree.QName(NS_ADM, "CintaInexistente"))
        etree.SubElement(error, etree.QName(NS_ADM, "cinta_id")).text = cinta_inexistente
    return _xml(sobre, 500)


@router.get("/soap")
def contrato(request: Request):
    if "wsdl" not in request.query_params:
        return Response("Use GET /soap?wsdl para el contrato o POST /soap para invocar.",
                        status_code=400, media_type="text/plain")
    ubicacion = f"{str(request.base_url).rstrip('/')}/soap"
    return Response(_WSDL.replace("{{UBICACION}}", ubicacion), media_type=TIPO_XML)


@router.post("/soap")
async def invocar(request: Request):
    try:
        sobre = etree.fromstring(await request.body(), _PARSER)
    except etree.XMLSyntaxError as error:
        return _fault("Client", f"XML invalido: {error}")

    cuerpo = sobre.find(f"{{{NS_SOAP}}}Body")
    if sobre.tag != f"{{{NS_SOAP}}}Envelope" or cuerpo is None or len(cuerpo) == 0:
        return _fault("Client", "se esperaba un sobre SOAP 1.1 con Body")

    operacion = cuerpo[0]
    if operacion.tag != f"{{{NS_ADM}}}ConsultarCinta":
        return _fault("Client", f"operacion desconocida: {etree.QName(operacion).localname}")

    cinta_id = (operacion.findtext(f"{{{NS_ADM}}}cinta_id") or "").strip()
    if not cinta_id:
        return _fault("Client", "falta cinta_id")

    try:
        estado = await asyncio.to_thread(_consultar_cinta, cinta_id)
    except DBAPIError:
        return _fault("Server", "base no disponible, reintente")
    if estado is None:
        return _fault("Client", f"cinta {cinta_id} no existe", cinta_inexistente=cinta_id)
    return _respuesta(estado)
