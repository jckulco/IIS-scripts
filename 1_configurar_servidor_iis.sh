#!/usr/bin/env bash
# Configurador de RHEL 9.6 para IIS:
# - (Inicio) Apaga y deshabilita firewalld
# - (Inicio) Forza SELINUX=disabled en /etc/selinux/config
# - (Inicio) Agrega límites a /etc/security/limits.conf
# - (Inicio) Reemplaza /etc/pam.d/other con contenido estándar solicitado
# - Establece hostname y actualiza /etc/hosts con la IPv4 detectada
# - Pide RAM (GB) y escribe sysctl con comentarios calculados

set -euo pipefail

if [[ ${EUID:-0} -ne 0 ]]; then
  echo "ERROR: ejecuta este script como root (o con sudo)." >&2
  exit 1
fi

ts="$(date +%Y%m%d-%H%M%S)"

echo "==> 1) Deteniendo y deshabilitando firewalld..."
# Solicitado explícitamente:
service firewalld stop || true
systemctl disable firewalld || true

echo "==> 2) Configurando SELINUX=disabled en /etc/selinux/config..."
cp -a /etc/selinux/config "/etc/selinux/config.bak.${ts}"
# Cambia solo la clave SELINUX= (no SELINUXTYPE=)
if grep -Eq '^[[:space:]]*SELINUX=' /etc/selinux/config; then
  sed -i -E 's/^[[:space:]]*SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
else
  echo 'SELINUX=disabled' >> /etc/selinux/config
fi

echo "==> 3) Agregando límites a /etc/security/limits.conf..."
cp -a /etc/security/limits.conf "/etc/security/limits.conf.bak.${ts}"
# Evita duplicados exactos, luego agrega bloque
sed -i -E \
  -e '/^\*[[:space:]]+soft[[:space:]]+nofile[[:space:]]+10240$/d' \
  -e '/^\*[[:space:]]+hard[[:space:]]+nofile[[:space:]]+10240$/d' \
  -e '/^\*[[:space:]]+soft[[:space:]]+nproc[[:space:]]+unlimited$/d' \
  -e '/^\*[[:space:]]+hard[[:space:]]+nproc[[:space:]]+unlimited$/d' \
  /etc/security/limits.conf

cat >> /etc/security/limits.conf <<'EOF'

# ===== Límites agregados automáticamente =====
* soft nofile 10240
* hard nofile 10240
* soft nproc  unlimited
* hard nproc  unlimited
# ===== Fin límites agregados =====
EOF

echo "==> 4) Reemplazando /etc/pam.d/other..."
cp -a /etc/pam.d/other "/etc/pam.d/other.bak.${ts}"
cat > /etc/pam.d/other <<'EOF'
#%PAM-1.0
auth     required       pam_unix.so
account  required       pam_unix.so
password required       pam_unix.so
session  required       pam_unix.so
EOF

# --- Hostname y /etc/hosts ---
echo "==> 5) Configurando hostname..."
read -rp "Ingresa el NOMBRE de host deseado (ej. srv-iis-01.mi.dominio): " srvname
srvname="${srvname// /}"  # quita espacios

# Validación simple del nombre (DNS label + puntos)
if ! [[ "$srvname" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || [[ "$srvname" =~ ^- || "$srvname" =~ -$ ]]; then
  echo "ERROR: nombre de host inválido." >&2
  exit 1
fi

hostnamectl set-hostname "$srvname"

echo "==> 6) Detectando IPv4 principal..."
server_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
if [[ -z "${server_ip}" ]]; then
  server_ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}' || true)"
fi
if [[ -z "${server_ip}" ]]; then
  echo "ERROR: no se pudo determinar la IPv4 del servidor." >&2
  exit 1
fi
echo "IPv4 detectada: ${server_ip}"

echo "==> 7) Actualizando /etc/hosts..."
cp -a /etc/hosts "/etc/hosts.bak.${ts}"

# Limpiar cualquier línea previa con este hostname/IP para evitar duplicados
tmp1="$(mktemp)"
tmp2="$(mktemp)"
srv_esc="${srvname//./\\.}"
ip_esc="${server_ip//./\\.}"
sed -E "/(^|[[:space:]])${srv_esc}([[:space:]]|\$)/d" /etc/hosts > "${tmp1}"
sed -E "/^${ip_esc}[[:space:]]/d" "${tmp1}" > "${tmp2}"

# Insertar justo debajo de la línea ::1 localhost ... localhost6.localdomain6
awk -v ip="${server_ip}" -v hn="${srvname}" '
  BEGIN{done=0}
  {
    print
    if ($0 ~ /^::1[[:space:]]+localhost[[:space:]]+localhost\.localdomain[[:space:]]+localhost6[[:space:]]+localhost6\.localdomain6$/ && !done) {
      print ip " " hn
      done=1
    }
  }
  END{
    if (!done) print ip " " hn
  }
' "${tmp2}" > /etc/hosts

rm -f "${tmp1}" "${tmp2}"
echo "Archivo /etc/hosts actualizado."

# --- Parámetros sysctl basados en GB ---
echo "==> 8) Configurando parámetros sysctl..."
read -rp "Ingresa la memoria física del servidor (en GB, entero positivo): " GB

if ! [[ "$GB" =~ ^[0-9]+$ ]] || [[ "$GB" -le 0 ]]; then
  echo "ERROR: ingresa un número entero positivo (ej. 20, 32, 64)." >&2
  exit 1
fi

BYTES_PER_GIB=1073741824
msgmni=$((GB * 1024))          # 1024 * GB
semmni=$((GB * 256))           # 256 * GB (4to valor de kernel.sem)
shmmni=$((GB * 256))           # 256 * GB
shmmax=$((GB * BYTES_PER_GIB)) # GB a bytes

cp -a /etc/sysctl.conf "/etc/sysctl.conf.bak.${ts}"

sed -i -E \
  -e '/^kernel\.msgmax=/d' \
  -e '/^kernel\.msgmnb=/d' \
  -e '/^kernel\.msgmni=/d' \
  -e '/^kernel\.randomize_va_space=/d' \
  -e '/^kernel\.sem=/d' \
  -e '/^kernel\.shmall=/d' \
  -e '/^kernel\.shmmax=/d' \
  -e '/^kernel\.shmmni=/d' \
  /etc/sysctl.conf

{
  echo "# ===== Ajustes IIS generados automáticamente ($(date)) ====="
  echo "kernel.msgmax=65536"
  echo "kernel.msgmnb=65536"
  echo "#${GB} GB en memoria fisica en servidor IIS, 1024*cantidad de RAM en GB, entonces ${GB}*1024=${msgmni}"
  echo "kernel.msgmni=${msgmni}"
  echo "kernel.randomize_va_space=0"
  echo "#${GB} GB en memoria fisica en servidor IIS, 256*${GB}=${semmni}"
  echo "#kernel.semmni=${semmni}"
  echo "#kernel.semmns=256000"
  echo "#kernel.semmsl=250"
  echo "#kernel.semopm=32"
  echo "kernel.sem=250 256000 32 ${semmni}"
  echo "kernel.shmall=4294967296"
  echo "#${GB} GB en memoria fisica en servidor IIS, entonces ${GB} en bytes=${shmmax}"
  echo "kernel.shmmax=${shmmax}"
  echo "#${GB} GB en memoria fisica en servidor IIS, 256*${GB}=${shmmni}"
  echo "kernel.shmmni=${shmmni}"
  echo "# ===== Fin ajustes IIS ====="
} >> /etc/sysctl.conf

sysctl -p

echo
echo "✅ Listo."
echo "   - firewalld detenido y deshabilitado"
echo "   - SELINUX=disabled configurado (requiere reinicio para aplicar)"
echo "   - Límites agregados a /etc/security/limits.conf"
echo "   - /etc/pam.d/other reemplazado"
echo "   - Hostname: ${srvname}"
echo "   - IPv4: ${server_ip} agregada a /etc/hosts"
echo "   - sysctl aplicado para ${GB} GB"
echo "   * Respaldos creados con sufijo .bak.${ts}"
echo
echo "⚠️  Nota: El cambio de SELinux requiere REINICIO para entrar en efecto."
