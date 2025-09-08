#!/usr/bin/env bash
# Instalación unificada de librerías (RHEL/Rocky/Alma/CentOS 9.x)
# - Mata DNF colgado, asegura DNS
# - RHEL sin suscripción -> deshabilita repos, desactiva subscription-manager y usa CentOS Stream 9 (baseurl)
# - Ajusta dnf, limpia caché, actualiza y genera caché
# - Instala paquetes base con tolerancia
# - Log en /var/log/instalar_librerias_unificado.log

set -euo pipefail

LOG="/var/log/instalar_librerias_unificado.log"
exec > >(tee -a "$LOG") 2>&1

if [[ ${EUID:-0} -ne 0 ]]; then
  echo "ERROR: ejecuta este script como root (o con sudo)." >&2
  exit 1
fi

# ----- Paso -1: matar DNF colgado y limpiar locks -----
echo "==> Limpiando procesos/locks de DNF..."
pkill -9 dnf 2>/dev/null || true
rm -f /var/run/dnf.pid /var/run/yum.pid 2>/dev/null || true

# ----- Detectar OS -----
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
ARCH="$(uname -m)"
echo "==> Detectado: ${OS_ID} ${OS_VER} (${ARCH})"
echo "==> Log: ${LOG}"

# ----- Utilidades -----
dnf_cmd() {
  if [[ "${USE_CENTOS_REPOS:-0}" -eq 1 ]]; then
    command dnf --disableplugin=subscription-manager --disablerepo="*" --enablerepo="centos-stream-*" "$@"
  else
    command dnf "$@"
  fi
}
dnf_try() { dnf_cmd -q "$@" --setopt=tsflags=nodocs --allowerasing --skip-broken; }

install_best_effort() {
  local title="$1"; shift
  local pkgs=("$@")
  echo "==> Instalando: ${title}"
  local ok=() fail=()
  if dnf_try install -y "${pkgs[@]}"; then
    ok=("${pkgs[@]}")
  else
    for p in "${pkgs[@]}"; do
      if dnf_try install -y "$p"; then ok+=("$p"); else fail+=("$p"); fi
    done
  fi
  [[ ${#ok[@]}   -gt 0 ]] && echo "   ✓ Instalados: ${ok[*]}"
  [[ ${#fail[@]} -gt 0 ]] && echo "   ⚠ No disponibles: ${fail[*]}"
}

# ----- Paso 0: asegurar DNS -----
ensure_dns() {
  echo "==> Verificando resolución DNS..."
  local ok=0
  if command -v dig >/dev/null 2>&1; then
    dig +time=2 +tries=1 mirrorlist.centos.org A >/dev/null 2>&1 && ok=1 || true
  else
    ping -c1 -W1 mirrorlist.centos.org >/dev/null 2>&1 && ok=1 || true
  fi
  if [[ $ok -eq 1 ]]; then
    echo "   ✓ DNS resuelve correctamente."
    return
  fi
  echo "   ⚠ DNS no resuelve. Respaldando y fijando /etc/resolv.conf..."
  [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)"
  cat >/etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
options attempts:1 timeout:2
EOF
}
ensure_dns

# ----- Paso 1: ajustar DNF -----
echo "==> Ajustando /etc/dnf/dnf.conf..."
mkdir -p /etc/dnf
if ! grep -q '^\[main\]' /etc/dnf/dnf.conf 2>/dev/null; then
  echo "[main]" >/etc/dnf/dnf.conf
fi
grep -q '^fastestmirror=' /etc/dnf/dnf.conf 2>/dev/null || echo "fastestmirror=True" >> /etc/dnf/dnf.conf
grep -q '^max_parallel_downloads=' /etc/dnf/dnf.conf 2>/dev/null || echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf
grep -q '^ip_resolve=' /etc/dnf/dnf.conf 2>/dev/null || echo "ip_resolve=4" >> /etc/dnf/dnf.conf
grep -q '^timeout=' /etc/dnf/dnf.conf 2>/dev/null || echo "timeout=30" >> /etc/dnf/dnf.conf
grep -q '^retries=' /etc/dnf/dnf.conf 2>/dev/null || echo "retries=1" >> /etc/dnf/dnf.conf

# ----- Paso 2: preparar repos según distro -----
USE_CENTOS_REPOS=0

enable_rocky_alma_repos() {
  echo "==> Habilitando CRB/PowerTools (si están disponibles)..."
  command -v dnf >/dev/null 2>&1 && dnf -qy install dnf-plugins-core || true
  dnf config-manager --set-enabled crb        2>/dev/null || true
  dnf config-manager --set-enabled powertools 2>/dev/null || true
}

disable_all_repos() {
  echo "==> Deshabilitando TODOS los repos habilitados..."
  dnf config-manager --set-disabled \* 2>/dev/null || true
}

deactivate_subscription_plugin() {
  echo "==> Desactivando plugin subscription-manager en DNF..."
  mkdir -p /etc/dnf/plugins
  if [[ -f /etc/dnf/plugins/subscription-manager.conf ]]; then
    cp -a /etc/dnf/plugins/subscription-manager.conf{,.bak.$(date +%Y%m%d-%H%M%S)} 2>/dev/null || true
  fi
  cat > /etc/dnf/plugins/subscription-manager.conf <<'EOF'
[main]
enabled=0
EOF
}

write_centos_stream_repo_single_baseurl() {
  # Puedes cambiar el mirror principal con MIRROR_BASE (sin barra al final):
  # Ej: MIRROR_BASE="http://mirror.rackspace.com/CentOS/9-stream"
  local MIRROR_BASE="${MIRROR_BASE:-http://mirror.stream.centos.org/9-stream}"

  echo "==> Escribiendo repos CentOS Stream 9 (baseurl simple) en /etc/yum.repos.d/centos-stream-temp.repo ..."
  cat > /etc/yum.repos.d/centos-stream-temp.repo <<EOF
[centos-stream-baseos]
name=CentOS Stream 9 - BaseOS
baseurl=${MIRROR_BASE}/BaseOS/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
skip_if_unavailable=1

[centos-stream-appstream]
name=CentOS Stream 9 - AppStream
baseurl=${MIRROR_BASE}/AppStream/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
skip_if_unavailable=1

[centos-stream-crb]
name=CentOS Stream 9 - CRB
baseurl=${MIRROR_BASE}/CRB/\$basearch/os/
enabled=1
gpgcheck=0
priority=1
skip_if_unavailable=1
EOF
}

check_rhel_subscription_and_prepare_repos() {
  echo "==> Verificando suscripción en RHEL..."
  local has_sub=0
  if command -v subscription-manager >/dev/null 2>&1; then
    if subscription-manager status &>/dev/null; then
      subscription-manager status 2>/dev/null | grep -qi "Overall Status: *Current" && has_sub=1 || true
    fi
  fi
  if [[ $has_sub -eq 1 ]]; then
    echo "   ✓ Suscripción RHEL activa (Current)."
    dnf -qy install dnf-plugins-core || true
    dnf config-manager --set-enabled "codeready-builder-for-rhel-9-${ARCH}-rpms" 2>/dev/null || true
  else
    echo "   ⚠ Sin suscripción RHEL activa. Cambiando a repos de CentOS Stream 9."
    USE_CENTOS_REPOS=1
    deactivate_subscription_plugin
    disable_all_repos
    write_centos_stream_repo_single_baseurl
  fi
}

case "$OS_ID" in
  rhel)      check_rhel_subscription_and_prepare_repos ;;
  rocky|almalinux|centos)
             enable_rocky_alma_repos ;;
  *)
             echo "==> Distro no reconocida (ID=${OS_ID}); intentando CRB genérico..."
             enable_rocky_alma_repos ;;
esac

# ----- Paso 3: limpieza y actualización -----
echo "==> Limpiando caché..."
dnf_cmd clean all || true
rm -rf /var/cache/dnf/* || true

echo "==> Actualizando sistema (puede tardar)..."
dnf_cmd -y update || true

echo "==> Generando caché..."
dnf_cmd -v makecache || true

# ----- Paso 4: instalación de paquetes -----
PKGS_UNIFICADOS=(
  glibc
  libXp libXau libXext libX11 libxcb libXmu libXtst
  libnsl
  elfutils elfutils-libs
  gcc gcc-c++
  libgcc libstdc++ libaio
  pam pam.i686
  nss-softokn-freebl perl-Net-Ping.noarch
  bc lsof net-tools
  ed
)

install_best_effort "Paquetes base unificados" "${PKGS_UNIFICADOS[@]}"

echo
echo "✅ Listo."
echo "   - DNS verificado/ajustado"
echo "   - Repos preparados (${OS_ID}${USE_CENTOS_REPOS:+ -> CentOS Stream 9})"
echo "   - dnf configurado (IPv4, fastestmirror, timeouts)"
echo "   - Sistema actualizado y caché generado"
echo "   - Paquetes instalados (ver ⚠ si algo no estuvo disponible)"
echo "   * Log: ${LOG}"
