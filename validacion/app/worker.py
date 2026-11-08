"""
Componente validacion. Procesador de eventos.

Escucha paquete.recibido, aplica las reglas del tipo de paquete y publica
paquete.validado o paquete.rechazado. No guarda estado.
"""

import json
import logging
import secrets
import threading
import time

import pika

from app.config import (CLAVE_INTERNA, COLA_CONSUMIDORES, COLA_PREFETCH,
                        COLA_RECIBIDOS, EXCHANGE_EVENTOS, RABBITMQ_URL)
from app.reglas.registro import obtener_regla

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("validacion")


def _publicar(canal, routing_key, evento):
    canal.basic_publish(
        exchange=EXCHANGE_EVENTOS,
        routing_key=routing_key,
        body=json.dumps(evento),
        properties=pika.BasicProperties(
            content_type="application/json",
            delivery_mode=2,
            headers={"clave_interna": CLAVE_INTERNA},
        ),
        mandatory=True,
    )


def _motivo_de_rechazo(paquete):
    regla = obtener_regla(paquete["tipo_paquete"])
    if regla is None:
        return f"tipo_paquete '{paquete['tipo_paquete']}' no está registrado"
    es_valido, motivo = regla.es_valido(paquete)
    return None if es_valido else motivo


def procesar(canal, metodo, propiedades, cuerpo):
    try:
        clave = (propiedades.headers or {}).get("clave_interna", "")
        if not secrets.compare_digest(str(clave), CLAVE_INTERNA):
            LOG.error("Evento rechazado: credencial interna invalida")
            canal.basic_nack(delivery_tag=metodo.delivery_tag, requeue=False)
            return

        paquete = json.loads(cuerpo)
        motivo = _motivo_de_rechazo(paquete)
        if motivo is None:
            _publicar(canal, "paquete.validado", paquete)
        else:
            _publicar(canal, "paquete.rechazado", {
                "solicitud_id": paquete["solicitud_id"],
                "cinta_id": paquete["cinta_id"],
                "codigo_http": 422,
                "resultado": {"detail": motivo},
            })
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
            canal.confirm_delivery()
            canal.exchange_declare(exchange=EXCHANGE_EVENTOS, exchange_type="topic", durable=True)
            cola_fallidos = f"{COLA_RECIBIDOS}.fallidos"
            canal.queue_declare(queue=cola_fallidos, durable=True)
            canal.queue_declare(queue=COLA_RECIBIDOS, durable=True, arguments={
                "x-dead-letter-exchange": "",
                "x-dead-letter-routing-key": cola_fallidos,
            })
            canal.queue_bind(exchange=EXCHANGE_EVENTOS, queue=COLA_RECIBIDOS,
                             routing_key="paquete.recibido")
            canal.basic_qos(prefetch_count=COLA_PREFETCH)
            canal.basic_consume(queue=COLA_RECIBIDOS, on_message_callback=procesar)
            LOG.info("Consumidor activo: cola=%s", COLA_RECIBIDOS)
            canal.start_consuming()
        except Exception:
            LOG.exception("Consumidor desconectado; reintentando")
            time.sleep(2)
        finally:
            if conexion is not None and conexion.is_open:
                conexion.close()


def ejecutar():
    hilos = [threading.Thread(target=_consumir, name=f"consumidor-{i}", daemon=True)
             for i in range(max(1, COLA_CONSUMIDORES))]
    for hilo in hilos:
        hilo.start()
    for hilo in hilos:
        hilo.join()


if __name__ == "__main__":
    ejecutar()
