"""
Procesador de eventos de admision.

Escucha paquete.validado, decide el cupo en una transaccion ACID y publica
paquete.admitido o paquete.rechazado. El orden es commit, publicar, ack: asi
nunca se anuncia algo sin confirmar, y si el proceso cae antes de publicar, la
reentrega encuentra el resultado guardado y vuelve a publicarlo.
"""

import json
import logging
import secrets
import threading
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal

import pika
from fastapi import HTTPException
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from app.config import (CLAVE_INTERNA, COLA_CONSUMIDORES, COLA_PAUSA_PROCESAMIENTO_S,
                        COLA_PREFETCH, COLA_VALIDADOS, EXCHANGE_EVENTOS,
                        RABBITMQ_URL)
from app.db import Sesion
from app.modelos import ResultadoSolicitudCola
from app.servicios import ejecutar_admision

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("cola_worker")


def _bloquear_solicitud(sesion, solicitud_id: uuid.UUID):
    """Serializa las entregas duplicadas de una misma solicitud."""
    sesion.execute(
        text("SELECT pg_advisory_xact_lock(:clave)"),
        {"clave": solicitud_id.int & ((1 << 63) - 1)},
    )


def _registrar_error_integridad(solicitud_id: uuid.UUID, error: IntegrityError):
    """Guarda el rechazo de la restriccion tras revertir la transaccion fallida."""
    respuesta = {
        "detail": {
            "motivo": "la restriccion cupo_no_excedido rechazo la escritura",
            "error": str(error.orig),
        }
    }
    with Sesion.begin() as sesion:
        _bloquear_solicitud(sesion, solicitud_id)
        if sesion.get(ResultadoSolicitudCola, solicitud_id) is None:
            sesion.add(ResultadoSolicitudCola(
                id=solicitud_id, codigo_http=409, respuesta=respuesta))
    return 409, respuesta


def _decidir(solicitud_id: uuid.UUID, evento: dict, peso: Decimal):
    """Decide el cupo en una transaccion y devuelve (codigo, respuesta)."""
    with Sesion() as sesion:
        with sesion.begin():
            _bloquear_solicitud(sesion, solicitud_id)
            previo = sesion.get(ResultadoSolicitudCola, solicitud_id)
            if previo is not None:
                return previo.codigo_http, previo.respuesta

            if datetime.fromisoformat(evento["vence_en"]) <= datetime.now(timezone.utc):
                codigo = 410
                respuesta = {"detail": "la solicitud vencio antes de ser procesada"}
            else:
                try:
                    respuesta = ejecutar_admision(
                        sesion, str(evento["cinta_id"]),
                        str(evento["tipo_paquete"]), peso)
                    codigo = 200
                except HTTPException as error:
                    respuesta = {"detail": error.detail}
                    codigo = error.status_code

            sesion.add(ResultadoSolicitudCola(
                id=solicitud_id, codigo_http=codigo, respuesta=respuesta))
    return codigo, respuesta


def _publicar_resultado(canal, solicitud_id, cinta_id, codigo, respuesta):
    canal.basic_publish(
        exchange=EXCHANGE_EVENTOS,
        routing_key="paquete.admitido" if codigo == 200 else "paquete.rechazado",
        body=json.dumps({
            "solicitud_id": str(solicitud_id),
            "cinta_id": cinta_id,
            "codigo_http": codigo,
            "resultado": respuesta,
        }),
        properties=pika.BasicProperties(
            content_type="application/json",
            delivery_mode=2,
            headers={"clave_interna": CLAVE_INTERNA},
        ),
        mandatory=True,
    )


def procesar(ch, metodo, propiedades, cuerpo):
    try:
        clave = (propiedades.headers or {}).get("clave_interna", "")
        if not secrets.compare_digest(str(clave), CLAVE_INTERNA):
            LOG.error("Evento rechazado: credencial interna invalida")
            ch.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
            return

        evento = json.loads(cuerpo)
        solicitud_id = uuid.UUID(evento["solicitud_id"])
        peso = Decimal(str(evento["peso_kg"]))
        if COLA_PAUSA_PROCESAMIENTO_S > 0:
            time.sleep(COLA_PAUSA_PROCESAMIENTO_S)

        try:
            codigo, respuesta = _decidir(solicitud_id, evento, peso)
        except IntegrityError as error:
            LOG.exception("Solicitud %s rechazada por una restriccion de base", solicitud_id)
            codigo, respuesta = _registrar_error_integridad(solicitud_id, error)

        _publicar_resultado(ch, solicitud_id, evento["cinta_id"], codigo, respuesta)
        ch.basic_ack(delivery_tag=metodo.delivery_tag)
        LOG.info("Solicitud %s procesada con codigo %s", solicitud_id, codigo)
    except (KeyError, TypeError, ValueError):
        LOG.exception("Evento invalido enviado a la cola de fallidos")
        ch.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
    except Exception:
        LOG.exception("Fallo transitorio procesando evento; se reencolara")
        time.sleep(1)
        ch.basic_nack(delivery_tag=metodo.delivery_tag, requeue=True)


def _consumir_un_hilo():
    """Bucle de consumo de un hilo: conexion y canal propios.

    pika no permite compartir canales entre hilos, asi que cada consumidor
    abre los suyos. Los eventos se confirman uno por uno, despues del commit.
    """
    while True:
        conexion = None
        try:
            parametros = pika.URLParameters(RABBITMQ_URL)
            parametros.heartbeat = 30
            parametros.blocked_connection_timeout = 10
            conexion = pika.BlockingConnection(parametros)
            canal = conexion.channel()
            canal.confirm_delivery()
            canal.exchange_declare(exchange=EXCHANGE_EVENTOS, exchange_type="topic", durable=True)
            cola_fallidos = f"{COLA_VALIDADOS}.fallidos"
            canal.queue_declare(queue=cola_fallidos, durable=True)
            canal.queue_declare(
                queue=COLA_VALIDADOS,
                durable=True,
                arguments={
                    "x-dead-letter-exchange": "",
                    "x-dead-letter-routing-key": cola_fallidos,
                },
            )
            canal.queue_bind(exchange=EXCHANGE_EVENTOS, queue=COLA_VALIDADOS,
                             routing_key="paquete.validado")
            canal.basic_qos(prefetch_count=COLA_PREFETCH)
            canal.basic_consume(queue=COLA_VALIDADOS, on_message_callback=procesar)
            LOG.info("Consumidor activo: cola=%s hilo=%s",
                     COLA_VALIDADOS, threading.current_thread().name)
            canal.start_consuming()
        except Exception:
            LOG.exception("Consumidor desconectado; reintentando")
            time.sleep(2)
        finally:
            if conexion is not None and conexion.is_open:
                conexion.close()


def ejecutar():
    cantidad = max(1, COLA_CONSUMIDORES)
    if cantidad == 1:
        _consumir_un_hilo()
        return
    LOG.info("Iniciando %d consumidores en paralelo", cantidad)
    hilos = [
        threading.Thread(target=_consumir_un_hilo,
                         name=f"consumidor-{i}", daemon=True)
        for i in range(cantidad)
    ]
    for hilo in hilos:
        hilo.start()
    for hilo in hilos:
        hilo.join()


if __name__ == "__main__":
    ejecutar()
