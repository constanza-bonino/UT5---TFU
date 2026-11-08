"""Publicacion de eventos y escucha de invalidaciones de Cache-Aside."""

import json
import logging
import threading
import time

import pika
from pika.exceptions import AMQPError

from app.config import CLAVE_INTERNA, EXCHANGE_EVENTOS, RABBITMQ_URL

LOG = logging.getLogger("cola_ingreso")

# Cada hilo de publicacion conserva su conexion y su canal. pika no permite
# compartir conexiones entre hilos, pero abrir una conexion nueva por cada
# solicitud HTTP (apreton de manos TCP y AMQP, declaracion de cola y cierre)
# cuesta decenas de ms y agota al broker con rafagas de cientos de
# solicitudes concurrentes. Reutilizar el canal del hilo deja el costo de
# publicacion en el orden de 1 ms.
_estado_hilo = threading.local()


def _parametros():
    parametros = pika.URLParameters(RABBITMQ_URL)
    parametros.heartbeat = 30
    parametros.blocked_connection_timeout = 5
    return parametros


def verificar_broker():
    conexion = pika.BlockingConnection(_parametros())
    conexion.close()


def _cerrar_canal_de_hilo():
    for nombre in ("canal", "conexion"):
        objeto = getattr(_estado_hilo, nombre, None)
        try:
            if objeto is not None and objeto.is_open:
                objeto.close()
        except Exception:
            pass
        _estado_hilo.__dict__.pop(nombre, None)


def _canal_de_hilo():
    """Devuelve el canal persistente del hilo actual, reconectando si hizo falta."""
    conexion = getattr(_estado_hilo, "conexion", None)
    canal = getattr(_estado_hilo, "canal", None)
    if (conexion is not None and conexion.is_open
            and canal is not None and canal.is_open):
        return canal
    _cerrar_canal_de_hilo()
    conexion = pika.BlockingConnection(_parametros())
    canal = conexion.channel()
    canal.confirm_delivery()
    canal.exchange_declare(exchange=EXCHANGE_EVENTOS, exchange_type="topic", durable=True)
    _estado_hilo.conexion = conexion
    _estado_hilo.canal = canal
    return canal


def publicar(routing_key: str, evento: dict):
    """Publica un evento durable reutilizando el canal del hilo.

    Ante un error de AMQP se descarta el canal roto, se reconecta y se
    reintenta una sola vez. Es seguro porque los consumidores ignoran un
    solicitud_id ya registrado.
    """
    argumentos = {
        "exchange": EXCHANGE_EVENTOS,
        "routing_key": routing_key,
        "body": json.dumps(evento).encode(),
        "properties": pika.BasicProperties(
            content_type="application/json",
            delivery_mode=2,
            headers={"clave_interna": CLAVE_INTERNA},
        ),
        "mandatory": True,
    }
    try:
        _canal_de_hilo().basic_publish(**argumentos)
    except AMQPError:
        LOG.warning("canal AMQP roto; se reconecta y se reintenta una vez")
        _cerrar_canal_de_hilo()
        _canal_de_hilo().basic_publish(**argumentos)


def _escuchar_invalidaciones(cache):
    while True:
        conexion = None
        try:
            conexion = pika.BlockingConnection(_parametros())
            canal = conexion.channel()
            canal.exchange_declare(exchange=EXCHANGE_EVENTOS, exchange_type="topic", durable=True)
            cola = canal.queue_declare(queue="", exclusive=True, auto_delete=True).method.queue
            canal.queue_bind(exchange=EXCHANGE_EVENTOS, queue=cola, routing_key="paquete.admitido")

            def invalidar(_canal, _metodo, _propiedades, cuerpo):
                cinta_id = json.loads(cuerpo)["cinta_id"]
                cache.invalidar(f"cinta:{cinta_id}")

            canal.basic_consume(queue=cola, on_message_callback=invalidar, auto_ack=True)
            LOG.info("Escuchando invalidaciones de cache")
            canal.start_consuming()
        except Exception:
            LOG.exception("Listener de invalidacion desconectado; reintentando")
            time.sleep(2)
        finally:
            if conexion is not None and conexion.is_open:
                conexion.close()


def iniciar_listener_cache(cache):
    threading.Thread(
        target=_escuchar_invalidaciones, args=(cache,), daemon=True,
        name="cache-invalidation-listener",
    ).start()
