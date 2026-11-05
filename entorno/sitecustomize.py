# Agregado a mano el 27-oct-2026 (no viene con el SDK; una actualizacion de gcloud puede borrarlo).
# La red anuncia IPv6 pero no lo enruta, y Python intenta IPv6 primero: cada conexion a Google se
# cuelga ~20 s antes de caer a IPv4 y bq termina en timeout. Esto ordena las direcciones para que
# IPv4 vaya primero, sin quitar IPv6. Solo se carga si CLOUDSDK_PYTHON_SITEPACKAGES=1.
# Para deshacerlo: borrar este archivo y la variable de entorno.
import socket

_getaddrinfo_original = socket.getaddrinfo


def _getaddrinfo_ipv4_primero(*args, **kwargs):
    direcciones = _getaddrinfo_original(*args, **kwargs)
    return sorted(direcciones, key=lambda direccion: direccion[0] != socket.AF_INET)


socket.getaddrinfo = _getaddrinfo_ipv4_primero
