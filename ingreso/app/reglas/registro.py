from app.reglas.paquete_normal import ReglaPaqueteNormal
from app.reglas.paquete_fragil import ReglaPaqueteFragil
from app.reglas.base import IReglaValidacion

REGISTRO: dict[str, IReglaValidacion] = {
    "normal": ReglaPaqueteNormal(),
    "fragil": ReglaPaqueteFragil(),
}


def obtener_regla(tipo_paquete: str) -> IReglaValidacion | None:
    """Devuelve la regla registrada para ese tipo, o None si no existe (Fase C: eso también se rechaza)."""
    return REGISTRO.get(tipo_paquete)
