"""
UT4 - Cache-Aside (patron de rendimiento).

Permite atender consultas de lectura (GET /cintas/{cinta_id}) desde memoria
local sin necesidad de hacer una llamada HTTP a admision ni una consulta SQL a
la base de datos en cada pedido.

Funcionamiento segun Cache-Aside:
  1. La aplicacion verifica si el dato existe en cache y no expiro.
  2. Si existe (Cache Hit): se retorna directamente el valor guardado.
  3. Si no existe o expiro (Cache Miss): se consulta al servicio de origen,
     se almacena el resultado en cache con su TTL, y se retorna al cliente.
  4. Ante modificaciones (admision de un paquete), la cache se invalida para
     esa cinta, asegurando consistencia en la proxima lectura.
"""

import threading
import time
from typing import Any


class CacheAside:
    """Cache en memoria con expiracion por TTL e invalidacion selectiva."""

    def __init__(self):
        self._datos: dict[str, tuple[Any, float]] = {}
        self._lock = threading.Lock()
        self._hits = 0
        self._misses = 0

    def obtener(self, clave: str) -> tuple[Any | None, bool]:
        """
        Retorna (valor, hit).
        Si la clave existe y no ha expirado, retorna (copia_valor, True).
        Si no existe o expiro, retorna (None, False).
        """
        ahora = time.time()
        with self._lock:
            if clave in self._datos:
                valor, expira_en = self._datos[clave]
                if ahora < expira_en:
                    self._hits += 1
                    # Se retorna una copia superficial del diccionario para evitar mutaciones externas
                    return (dict(valor) if isinstance(valor, dict) else valor), True
                else:
                    # Expiro: se elimina
                    del self._datos[clave]
            self._misses += 1
            return None, False

    def guardar(self, clave: str, valor: Any, ttl_s: float):
        """Guarda un valor en cache con un tiempo de vida en segundos."""
        ahora = time.time()
        expira_en = ahora + ttl_s
        with self._lock:
            self._datos[clave] = (dict(valor) if isinstance(valor, dict) else valor, expira_en)

    def invalidar(self, clave: str) -> bool:
        """Invalida una clave especifica. Retorna True si existia."""
        with self._lock:
            return self._datos.pop(clave, None) is not None

    def limpiar(self):
        """Vacia completamente la cache."""
        with self._lock:
            self._datos.clear()

    def metricas(self) -> dict:
        """Retorna estadisticas de uso de la cache."""
        ahora = time.time()
        with self._lock:
            claves_activas = sum(1 for _, exp in self._datos.values() if ahora < exp)
            total = self._hits + self._misses
            ratio = (self._hits / total * 100) if total > 0 else 0.0
            return {
                "hits": self._hits,
                "misses": self._misses,
                "total_consultas": total,
                "hit_ratio_porcentaje": round(ratio, 2),
                "claves_activas": claves_activas,
            }


# Instancia singleton para el proceso de ingreso.
cache_cintas = CacheAside()
