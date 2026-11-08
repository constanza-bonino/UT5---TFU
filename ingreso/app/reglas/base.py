from abc import ABC, abstractmethod


class IReglaValidacion(ABC):
    @abstractmethod
    def es_valido(self, paquete: dict) -> tuple[bool, str | None]:
        """
        Debe devolver (True, None) si el paquete es válido, o
        (False, "motivo del rechazo") si no lo es.
        """
        raise NotImplementedError
