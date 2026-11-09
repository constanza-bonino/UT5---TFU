"""
UT4 - Health Endpoint Monitoring: monitor externo.

Consulta el /health/ready de cada replica y escribe solo los cambios de estado:
OK, DEGRADADO (503), SIN RESPUESTA o FUERA (ya no esta en el DNS).

UT5: los procesadores de eventos (validacion, procesador_cola) no tienen HTTP,
asi que se los vigila por sus colas, con la API de administracion de RabbitMQ.
Una cola sin consumidores quiere decir que su procesador esta caido; los
eventos no se pierden, se acumulan hasta que vuelve.
"""

import base64
import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

SERVICIOS = [s.strip() for s in
             os.getenv("MONITOR_SERVICIOS", "ingreso:8000,admision:8000").split(",")]
COLAS = [c.strip() for c in os.getenv("MONITOR_COLAS", "").split(",") if c.strip()]
RABBITMQ_API = os.getenv("MONITOR_RABBITMQ_API", "http://rabbitmq:15672")
RABBITMQ_USUARIO = os.getenv("MONITOR_RABBITMQ_USUARIO", "tfu")
RABBITMQ_CLAVE = os.getenv("MONITOR_RABBITMQ_CLAVE", "tfu")
INTERVALO_S = float(os.getenv("MONITOR_INTERVALO_S", 2))
TIMEOUT_S = float(os.getenv("MONITOR_TIMEOUT_S", 4))
RUTA = "/health/ready"


def ahora():
    # UTC, para que los scripts puedan comparar contra su propio reloj.
    return datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def nombre_de(ip):
    """El DNS de Docker resuelve la IP al nombre del contenedor."""
    try:
        return socket.gethostbyaddr(ip)[0].split(".")[0]
    except OSError:
        return ip


def descubrir(servicio):
    """Devuelve {nombre_contenedor: ip} de las replicas vivas del servicio."""
    host, puerto = servicio.split(":")
    try:
        ips = {info[4][0] for info in
               socket.getaddrinfo(host, int(puerto), type=socket.SOCK_STREAM)}
    except socket.gaierror:
        return {}
    return {nombre_de(ip): ip for ip in ips}


def consultar(ip, puerto):
    """Devuelve (estado, detalle) de una replica."""
    try:
        with urllib.request.urlopen(f"http://{ip}:{puerto}{RUTA}",
                                    timeout=TIMEOUT_S) as r:
            return "OK", ""
    except urllib.error.HTTPError as error:
        try:
            chequeos = json.loads(error.read().decode()).get("chequeos", {})
            fallas = [f"{n}: {c.get('error', '?')}"
                      for n, c in chequeos.items() if not c.get("ok")]
            detalle = "; ".join(fallas)
        except Exception:
            detalle = ""
        return "DEGRADADO", detalle or f"HTTP {error.code}"
    except Exception as error:
        return "SIN RESPUESTA", type(error).__name__


def consultar_cola(cola):
    """Devuelve (estado, detalle) de una cola segun sus consumidores."""
    url = f"{RABBITMQ_API}/api/queues/%2F/{urllib.parse.quote(cola, safe='')}"
    credencial = base64.b64encode(f"{RABBITMQ_USUARIO}:{RABBITMQ_CLAVE}".encode()).decode()
    pedido = urllib.request.Request(url, headers={"Authorization": f"Basic {credencial}"})
    try:
        with urllib.request.urlopen(pedido, timeout=TIMEOUT_S) as r:
            datos = json.loads(r.read().decode())
    except urllib.error.HTTPError as error:
        return "SIN DATOS", f"HTTP {error.code}"
    except Exception as error:
        return "SIN DATOS", f"broker sin respuesta ({type(error).__name__})"

    consumidores, mensajes = datos.get("consumers", 0), datos.get("messages", 0)
    detalle = f"{consumidores} consumidores, {mensajes} eventos en espera"
    return ("OK" if consumidores > 0 else "SIN CONSUMIDORES"), detalle


def ronda(pool):
    """Consulta todas las replicas y todas las colas en paralelo."""
    tareas = {}
    for servicio in SERVICIOS:
        puerto = servicio.split(":")[1]
        for nombre, ip in descubrir(servicio).items():
            tareas[nombre] = pool.submit(consultar, ip, puerto)
    for cola in COLAS:
        tareas[f"cola {cola}"] = pool.submit(consultar_cola, cola)
    return {nombre: tarea.result() for nombre, tarea in tareas.items()}


def main():
    print(f"{ahora()}  monitor iniciado: {', '.join(SERVICIOS + COLAS)} "
          f"cada {INTERVALO_S:g} s (timeout {TIMEOUT_S:g} s)", flush=True)

    conocido = {}   # nombre -> (estado, detalle)
    with ThreadPoolExecutor(max_workers=16) as pool:
        while True:
            inicio = time.monotonic()
            actual = ronda(pool)

            # Replicas que desaparecieron del DNS.
            for nombre in conocido.keys() - actual.keys():
                if conocido[nombre][0] != "FUERA":
                    actual[nombre] = ("FUERA", "ya no figura en el DNS")
                else:
                    actual[nombre] = conocido[nombre]

            for nombre in sorted(actual):
                estado, detalle = actual[nombre]
                anterior, detalle_anterior = conocido.get(nombre, ("NUEVA", ""))
                # Con una cola sin consumidores tambien se informa cuando crece la
                # espera: muestra que los eventos se guardan y no se pierden.
                acumulando = estado == "SIN CONSUMIDORES" and detalle != detalle_anterior
                if estado != anterior or acumulando:
                    linea = f"{ahora()}  {nombre:<30} {anterior:>16} -> {estado}"
                    print(linea + (f"  ({detalle})" if detalle else ""), flush=True)

            conocido = actual
            time.sleep(max(0, INTERVALO_S - (time.monotonic() - inicio)))


if __name__ == "__main__":
    main()
