"""
UT4 - Health Endpoint Monitoring: monitor externo.

Consulta el /health/ready de cada replica y escribe solo los cambios de estado:
OK, DEGRADADO (503), SIN RESPUESTA o FUERA (ya no esta en el DNS).
"""

import json
import os
import socket
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

SERVICIOS = [s.strip() for s in
             os.getenv("MONITOR_SERVICIOS", "ingreso:8000,admision:8000").split(",")]
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


def ronda(pool):
    """Consulta todas las replicas de todos los servicios en paralelo."""
    tareas = {}
    for servicio in SERVICIOS:
        puerto = servicio.split(":")[1]
        for nombre, ip in descubrir(servicio).items():
            tareas[nombre] = pool.submit(consultar, ip, puerto)
    return {nombre: tarea.result() for nombre, tarea in tareas.items()}


def main():
    print(f"{ahora()}  monitor iniciado: {', '.join(SERVICIOS)} "
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
                anterior = conocido.get(nombre, ("NUEVA", ""))[0]
                if estado != anterior:
                    linea = f"{ahora()}  {nombre:<22} {anterior:>13} -> {estado}"
                    print(linea + (f"  ({detalle})" if detalle else ""), flush=True)

            conocido = actual
            time.sleep(max(0, INTERVALO_S - (time.monotonic() - inicio)))


if __name__ == "__main__":
    main()
