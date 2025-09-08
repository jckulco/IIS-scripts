#!/usr/bin/env bash
# Script: 3_env_setup.sh
# Objetivo:
#  1) umask 022
#  2) export IBM_JAVA_OPTIONS=
#  3) unset -f which
#  4) set | grep -i func
#  5) set | grep -i which

# 1) Establecer umask
echo ">> umask 022"
umask 022

# 2) Limpiar IBM_JAVA_OPTIONS (dejarla definida pero vacía)
echo ">> export IBM_JAVA_OPTIONS="
export IBM_JAVA_OPTIONS=

# 3) Eliminar función 'which' si existe (no afecta binarios/aliases)
echo ">> unset -f which"
unset -f which 2>/dev/null || true

# 4) Mostrar funciones (búsqueda por 'func' en la salida de 'set')
echo ">> set | grep -i func"
set | grep -i func || true

# 5) Mostrar coincidencias con 'which' en la salida de 'set'
echo ">> set | grep -i which"
set | grep -i which || true
