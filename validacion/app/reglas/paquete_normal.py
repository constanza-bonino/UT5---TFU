from app.config import LIMITES
from app.reglas.base import IReglaValidacion


class ReglaPaqueteNormal(IReglaValidacion):
    def es_valido(self, paquete: dict) -> tuple[bool, str | None]:
        limites = LIMITES["normal"]

        if paquete["peso_kg"] > limites["peso_kg_max"]:
            return False, (
                f"peso_kg ({paquete['peso_kg']}) excede el máximo permitido "
                f"({limites['peso_kg_max']}) para tipo 'normal'"
            )
        if paquete["alto_cm"] > limites["alto_cm_max"]:
            return False, (
                f"alto_cm ({paquete['alto_cm']}) excede el máximo permitido "
                f"({limites['alto_cm_max']}) para tipo 'normal'"
            )
        if paquete["ancho_cm"] > limites["ancho_cm_max"]:
            return False, (
                f"ancho_cm ({paquete['ancho_cm']}) excede el máximo permitido "
                f"({limites['ancho_cm_max']}) para tipo 'normal'"
            )
        if paquete["largo_cm"] > limites["largo_cm_max"]:
            return False, (
                f"largo_cm ({paquete['largo_cm']}) excede el máximo permitido "
                f"({limites['largo_cm_max']}) para tipo 'normal'"
            )

        return True, None