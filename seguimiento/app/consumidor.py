"""Consume paquete.recibido y los resultados finales, y actualiza la vista."""

import json
import logging
import secrets
import threading
import time
import uuid
from datetime import datetime

import pika

from app import vista
from app.config import (CLAVE_INTERNA, COLA_CONSUMIDORES, COLA_PREFETCH,
                        COLA_RESULTADOS, EXCHANGE_EVENTOS, RABBITMQ_URL)

LOG = logging.getLogger("seguimiento")

ESTADOS = {"paquete.admitido": "admitida", "paquete.rechazado": "rechazada"}
RECIBIDO = "paquete.recibido"


def procesar(canal, metodo, propiedades, cuerpo):
    try:
        # Solo un evento autentico puede marcar una solicitud como admitida.
        clave = (propiedades.headers or {}).get("clave_interna", "")
        if not secrets.compare_digest(str(clave), CLAVE_INTERNA):
            LOG.error("Evento rechazado: credencial interna invalida")
            canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
            return

        evento = json.loads(cuerpo)
        solicitud_id = uuid.UUID(evento["solicitud_id"])
        if metodo.routing_key == RECIBIDO:
            vista.guardar_recibida(solicitud_id, datetime.fromisoformat(evento["vence_en"]))
            LOG.info("Solicitud %s: paquete.recibido -> pendiente", solicitud_id)
        else:
            estado = ESTADOS[metodo.routing_key]
            vista.guardar_resultado(solicitud_id, estado,
                                    int(evento["codigo_http"]), evento["resultado"])
            LOG.info("Solicitud %s: %s -> %s", solicitud_id, metodo.routing_key, estado)
        canal.basic_ack(delivery_tag=metodo.delivery_tag)
    except (KeyError, TypeError, ValueError):
        LOG.exception("Evento invalido enviado a la cola de fallidos")
        canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
    except Exception:
        LOG.exception("Fallo transitorio procesando evento; se reencolara")
        time.sleep(1)
        canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=True)


def _consumir():
    while True:
        conexion = None
        try:
            parametros = pika.URLParameters(RABBITMQ_URL)
            parametros.heartbeat = 30
            conexion = pika.BlockingConnection(parametros)
            canal = conexion.channel()
            canal.exchange_declare(exchange=EXCHANGE_EVENTOS, exchange_type="topic", durable=True)
            cola_fallidos = f"{COLA_RESULTADOS}.fallidos"
            canal.queue_declare(queue=cola_fallidos, durable=True)
            canal.queue_declare(queue=COLA_RESULTADOS, durable=True, arguments={
                "x-dead-letter-exchange": "",
                "x-dead-letter-routing-key": cola_fallidos,
            })
            for routing_key in (RECIBIDO, *ESTADOS):
                canal.queue_bind(exchange=EXCHANGE_EVENTOS, queue=COLA_RESULTADOS,
                                 routing_key=routing_key)
            canal.basic_qos(prefetch_count=COLA_PREFETCH)
            canal.basic_consume(queue=COLA_RESULTADOS, on_message_callback=procesar)
            LOG.info("Consumidor activo: cola=%s", COLA_RESULTADOS)
            canal.start_consuming()
        except Exception:
            LOG.exception("Consumidor desconectado; reintentando")
            time.sleep(2)
        finally:
            if conexion is not None and conexion.is_open:
                conexion.close()


def iniciar():
    for i in range(max(1, COLA_CONSUMIDORES)):
        threading.Thread(target=_consumir, name=f"consumidor-{i}", daemon=True).start()
