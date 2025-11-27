#!/bin/bash
# 3_variables_de_entorno_iis.sh
# Ejecuta el instalador con entorno limpio, umask 022 e IBM_JAVA_OPTIONS vacío.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 /ruta/al/setup [args...]"
  exit 2
fi

INSTALLER="$1"; shift
if [[ ! -x "$INSTALLER" ]]; then
  echo "Error: $INSTALLER no existe o no es ejecutable."
  exit 1
fi

# PATH mínimo
MIN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "Entorno limpio listo. Ejecutando instalador..."
echo "Comando: $INSTALLER ${*:-}"

# Lanza un bash con entorno vacío; pasa el instalador como $0 y los args como $@
exec /usr/bin/env -i \
  PATH="$MIN_PATH" \
  HOME="${HOME:-/root}" \
  LANG="en_US.UTF-8" \
  LC_ALL="en_US.UTF-8" \
  IBM_JAVA_OPTIONS="" \
  /bin/bash -c ' \
    set -euo pipefail
    umask 022
    # Comprobación defensiva: no debe haber funciones exportadas
    if env | grep -q "^BASH_FUNC_"; then
      echo "ERROR: aún hay BASH_FUNC_* en el entorno:"
      env | grep "^BASH_FUNC_"
      exit 1
    fi
    exec "$0" "$@"
  ' "$INSTALLER" "$@"
