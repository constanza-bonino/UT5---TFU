"""
UT5 - Circuit Breaker.

Protege la llamada SOAP de ingreso a admision. Sin el, si admision se cuelga
(acepta la conexion pero no contesta), cada consulta espera el timeout entero:
la red no es confiable y la latencia no es cero. Con el, despues de varios
fallos seguidos se deja de llamar por un rato y se responde 503 al instante.

  CERRADO       las llamadas pasan. Se cuentan los fallos seguidos.
  ABIERTO       las llamadas se rechazan sin tocar la red, durante APERTURA_S.
  SEMIABIERTO   pasada la apertura, se deja pasar una sola llamada de prueba:
                si anda se cierra, si falla se vuelve a abrir.

Solo cuentan como fallo los problemas de comunicacion (timeout, conexion,
SOAP Fault de servidor). Un Fault CintaInexistente es una respuesta correcta
del servicio y no abre el circuito.

Corre en el bucle de eventos de ingreso: no hay await entre leer y cambiar el
estado, asi que no hace falta un candado.
"""

import logging
import time

LOG = logging.getLogger("circuito")

CERRADO, ABIERTO, SEMIABIERTO = "cerrado", "abierto", "semiabierto"


class CircuitBreaker:

    def __init__(self, nombre, umbral_fallos, apertura_s):
        self.nombre = nombre
        self.umbral_fallos = umbral_fallos
        self.apertura_s = apertura_s
        self.estado = CERRADO
        self.fallos_seguidos = 0
        self.abierto_en = 0.0
        self.prueba_en_curso = False
        self.rechazadas = 0

    def _cambiar(self, nuevo, motivo):
        LOG.warning("circuito %s: %s -> %s (%s)", self.nombre, self.estado, nuevo, motivo)
        self.estado = nuevo

    def permitir(self):
        """True si la llamada puede salir a la red."""
        if self.estado == ABIERTO:
            if time.monotonic() - self.abierto_en < self.apertura_s:
                self.rechazadas += 1
                return False
            self._cambiar(SEMIABIERTO, "termino la apertura, se prueba una llamada")

        if self.estado == SEMIABIERTO:
            if self.prueba_en_curso:
                self.rechazadas += 1
                return False
            self.prueba_en_curso = True
        return True

    def exito(self):
        self.prueba_en_curso = False
        self.fallos_seguidos = 0
        if self.estado != CERRADO:
            self._cambiar(CERRADO, "la llamada de prueba respondio")

    def fallo(self):
        self.prueba_en_curso = False
        self.fallos_seguidos += 1
        if self.estado == SEMIABIERTO or self.fallos_seguidos >= self.umbral_fallos:
            if self.estado != ABIERTO:
                self._cambiar(ABIERTO, f"{self.fallos_seguidos} fallos seguidos")
            self.abierto_en = time.monotonic()

    def segundos_para_reintentar(self):
        if self.estado != ABIERTO:
            return 0
        return max(0, round(self.apertura_s - (time.monotonic() - self.abierto_en), 1))

    def resumen(self):
        return {
            "circuito": self.nombre,
            "estado": self.estado,
            "fallos_seguidos": self.fallos_seguidos,
            "umbral_fallos": self.umbral_fallos,
            "apertura_s": self.apertura_s,
            "segundos_para_reintentar": self.segundos_para_reintentar(),
            "llamadas_rechazadas_sin_red": self.rechazadas,
        }
