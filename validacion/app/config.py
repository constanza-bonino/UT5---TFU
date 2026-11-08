import os

from dotenv import load_dotenv

load_dotenv()


def _limite(nombre_var: str, valor_default: float) -> float:
    """Lee una variable de entorno numérica, con fallback a un default."""
    return float(os.getenv(nombre_var, valor_default))


LIMITES = {
    "normal": {
        "peso_kg_max": _limite("LIMITE_NORMAL_PESO_KG_MAX", 25),
        "alto_cm_max": _limite("LIMITE_NORMAL_ALTO_CM_MAX", 60),
        "ancho_cm_max": _limite("LIMITE_NORMAL_ANCHO_CM_MAX", 60),
        "largo_cm_max": _limite("LIMITE_NORMAL_LARGO_CM_MAX", 80),
    },
    "fragil": {
        "peso_kg_max": _limite("LIMITE_FRAGIL_PESO_KG_MAX", 8),
        "alto_cm_max": _limite("LIMITE_FRAGIL_ALTO_CM_MAX", 40),
        "ancho_cm_max": _limite("LIMITE_FRAGIL_ANCHO_CM_MAX", 40),
        "largo_cm_max": _limite("LIMITE_FRAGIL_LARGO_CM_MAX", 50),
    },
}

RABBITMQ_URL = os.getenv("RABBITMQ_URL", "amqp://tfu:tfu@rabbitmq:5672/%2F")
EXCHANGE_EVENTOS = os.getenv("EXCHANGE_EVENTOS", "cinta.eventos")
COLA_RECIBIDOS = os.getenv("COLA_RECIBIDOS", "validacion.recibidos")
COLA_CONSUMIDORES = int(float(os.getenv("COLA_CONSUMIDORES", 8)))
COLA_PREFETCH = int(float(os.getenv("COLA_PREFETCH", 1)))
CLAVE_INTERNA = os.getenv("CLAVE_INTERNA", "cinta-interna-dev")
