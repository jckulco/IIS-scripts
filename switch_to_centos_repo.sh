#!/usr/bin/env bash
# **************************************************************
#  NO SOPORTADO POR RED HAT - USO DE LABORATORIO / DEMOS
#  Deshabilita repos de RHEL y habilita repos de CentOS
#  (CentOS Stream 8/9 o CentOS 7 vault) según versión detectada.
# **************************************************************

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Este script debe ejecutarse como root." >&2
  exit 1
fi

PKGMGR="$(command -v dnf || command -v yum || true)"
if [[ -z "${PKGMGR}" ]]; then
  echo "No se encontró ni dnf ni yum. Abortando." >&2
  exit 1
fi

# Detectar versión mayor de RHEL (7/8/9)
RHEL_MAJOR="$(rpm -E %rhel 2>/dev/null || true)"
if [[ -z "${RHEL_MAJOR}" ]]; then
  echo "No se pudo detectar la versión de RHEL con 'rpm -E %rhel'." >&2
  exit 1
fi

echo ">> Detectado RHEL mayor: ${RHEL_MAJOR}"
sleep 1

# 1) Backup de repos existentes
BACKUP_DIR="/root/backup-repos-$(date +%Y%m%d-%H%M%S)"
echo ">> Respaldando /etc/yum.repos.d/*.repo en ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
cp -a /etc/yum.repos.d/*.repo "${BACKUP_DIR}" 2>/dev/null || true

# 2) Deshabilitar repos manejados por subscription-manager
if command -v subscription-manager &>/dev/null; then
  echo ">> Deshabilitando repos de subscription-manager (si hay)..."
  subscription-manager repos --disable="*" || true
  subscription-manager config --rhsm.manage_repos=0 || true
fi

# 3) Renombrar repos de Red Hat para que no se usen
echo ">> Renombrando repos de Red Hat..."
cd /etc/yum.repos.d
for f in redhat.repo *.rhsm *.rhel*.repo; do
  [[ -e "$f" ]] || continue
  mv "$f" "$f.disabled"
done

# 4) Importar llave GPG oficial de CentOS
echo ">> Importando llave GPG de CentOS..."
if [[ ! -f /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial ]]; then
  curl -fsSL -o /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial \
    https://www.centos.org/keys/RPM-GPG-KEY-CentOS-Official
fi
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial || true

# 5) Crear archivo de repos según versión de RHEL
echo ">> Creando archivo de repos CentOS para RHEL ${RHEL_MAJOR}..."

case "${RHEL_MAJOR}" in
  9)
    cat > /etc/yum.repos.d/centos-stream.repo << 'EOR'
[baseos]
name=CentOS Stream 9 - BaseOS
baseurl=https://mirror.stream.centos.org/9-stream/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[appstream]
name=CentOS Stream 9 - AppStream
baseurl=https://mirror.stream.centos.org/9-stream/AppStream/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[crb]
name=CentOS Stream 9 - CRB
baseurl=https://mirror.stream.centos.org/9-stream/CRB/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[extras]
name=CentOS Stream 9 - Extras
baseurl=https://mirror.stream.centos.org/SIGs/9-stream/extras/$basearch/extras-common/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOR
    ;;

  8)
    cat > /etc/yum.repos.d/centos-stream.repo << 'EOR'
[baseos]
name=CentOS Stream 8 - BaseOS
baseurl=https://mirror.stream.centos.org/8-stream/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[appstream]
name=CentOS Stream 8 - AppStream
baseurl=https://mirror.stream.centos.org/8-stream/AppStream/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[powertools]
name=CentOS Stream 8 - PowerTools
baseurl=https://mirror.stream.centos.org/8-stream/PowerTools/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[extras]
name=CentOS Stream 8 - Extras
baseurl=https://mirror.stream.centos.org/8-stream/extras/$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOR
    ;;

  7)
    cat > /etc/yum.repos.d/centos-linux7.repo << 'EOR'
[base]
name=CentOS 7 - Base
baseurl=http://vault.centos.org/7.9.2009/os/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[updates]
name=CentOS 7 - Updates
baseurl=http://vault.centos.org/7.9.2009/updates/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial

[extras]
name=CentOS 7 - Extras
baseurl=http://vault.centos.org/7.9.2009/extras/$basearch/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
EOR
    ;;

  *)
    echo "RHEL ${RHEL_MAJOR} no está soportado por este script." >&2
    exit 1
    ;;
esac

# 6) Limpiar caché y generar metadata
echo ">> Limpiando caché de ${PKGMGR}..."
${PKGMGR} clean all -y || ${PKGMGR} clean all || true

echo ">> Generando metadata..."
${PKGMGR} makecache -y || ${PKGMGR} makecache

echo ">> Repos activos:"
${PKGMGR} repolist || true

echo
echo "Listo. Ahora estás usando repos de CentOS (uso de laboratorio)."
echo "Ejemplo:  ${PKGMGR} install -y wget curl"
