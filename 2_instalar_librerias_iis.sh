#!/usr/bin/env bash
# Instalación unificada de librerías (RHEL/Rocky/Alma/CentOS 9.x)
# - Repo fallback a CentOS Stream si no hay suscripción
# - Paquetes base (tolerante)
# - PAM 64/32 bits (directo, sin skip-broken)
# - Verificación libpam.so.0
# - Log: /var/log/instalar_librerias_unificado.log

set -euo pipefail
trap 'echo "💥 Falló en línea $LINENO: comando '\''$BASH_COMMAND'\''"; exit 99' ERR

LOG="/var/log/instalar_librerias_unificado.log"
exec > >(tee -a "$LOG") 2>&1

[[ ${EUID:-0} -eq 0 ]] || { echo "ERROR: ejecuta como root"; exit 1; }

echo "==> Limpiando procesos/locks de DNF..."
pkill -9 dnf 2>/dev/null || true
rm -f /var/run/dnf.pid /var/run/yum.pid 2>/dev/null || true

source /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-unknown}"
ARCH="$(uname -m)"
echo "==> Detectado: ${OS_ID} ${OS_VER} (${ARCH})"
echo "==> Log: ${LOG}"

USE_CENTOS_REPOS=0

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
  if (( ${#ok[@]} > 0 )); then
    echo "   ✓ Instalados: ${ok[*]}"
  fi
  if (( ${#fail[@]} > 0 )); then
    echo "   ⚠ No disponibles (saltados): ${fail[*]}"
  fi
}

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
  else
    echo "   ⚠ DNS no resuelve. Ajustando /etc/resolv.conf..."
    [[ -f /etc/resolv.conf ]] && cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)"
    cat >/etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
options attempts:1 timeout:2
EOF
  fi
}
ensure_dns

echo "==> Ajustando /etc/dnf/dnf.conf..."
mkdir -p /etc/dnf
grep -q '^\[main\]' /etc/dnf/dnf.conf 2>/dev/null || echo "[main]" >/etc/dnf/dnf.conf
grep -q '^fastestmirror=' /etc/dnf/dnf.conf 2>/dev/null || echo "fastestmirror=True" >> /etc/dnf/dnf.conf
grep -q '^max_parallel_downloads=' /etc/dnf/dnf.conf 2>/dev/null || echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf
grep -q '^ip_resolve=' /etc/dnf/dnf.conf 2>/dev/null || echo "ip_resolve=4" >> /etc/dnf/dnf.conf
grep -q '^timeout=' /etc/dnf/dnf.conf 2>/dev/null || echo "timeout=30" >> /etc/dnf/dnf.conf
grep -q '^retries=' /etc/dnf/dnf.conf 2>/dev/null || echo "retries=1" >> /etc/dnf/dnf.conf

enable_rocky_alma_repos() {
  echo "==> Habilitando CRB/PowerTools (si aplica)..."
  dnf -qy install dnf-plugins-core || true
  dnf config-manager --set-enabled crb        2>/dev/null || true
  dnf config-manager --set-enabled powertools 2>/dev/null || true
}

disable_all_repos() {
  echo "==> Deshabilitando TODOS los repos habilitados..."
  dnf config-manager --set-disabled \* 2>/dev/null || true
}

deactivate_subscription_plugin() {
  echo "==> Desactivando subscription-manager en DNF..."
  mkdir -p /etc/dnf/plugins
  [[ -f /etc/dnf/plugins/subscription-manager.conf ]] && \
    cp -a /etc/dnf/plugins/subscription-manager.conf{,.bak.$(date +%Y%m%d-%H%M%S)} || true
  cat > /etc/dnf/plugins/subscription-manager.conf <<'EOF'
[main]
enabled=0
EOF
}

write_centos_stream_repo_single_baseurl() {
  local MIRROR_BASE="${MIRROR_BASE:-http://mirror.stream.centos.org/9-stream}"
  echo "==> Escribiendo repos CentOS Stream 9 (baseurl simple)..."
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
    echo "   ⚠ Sin suscripción RHEL activa. Usando repos de CentOS Stream 9."
    USE_CENTOS_REPOS=1
    deactivate_subscription_plugin
    disable_all_repos
    write_centos_stream_repo_single_baseurl
  fi
}

case "$OS_ID" in
  rhel) check_rhel_subscription_and_prepare_repos ;;
  rocky|almalinux|centos) enable_rocky_alma_repos ;;
  *) echo "==> Distro (ID=${OS_ID}) no reconocida; intento CRB genérico..."; enable_rocky_alma_repos ;;
esac

echo "==> Limpiando caché..."
dnf_cmd clean all || true
rm -rf /var/cache/dnf/* || true

echo "==> Actualizando sistema..."
dnf_cmd -y update || true

echo "==> Generando caché..."
dnf_cmd -v makecache || true

# ==========================
#  PAQUETES BASE
# ==========================
PKGS_UNIFICADOS=(
  glibc
  libXp libXau libXext libX11 libxcb libXmu libXtst
  libnsl
  elfutils elfutils-libs
  gcc gcc-c++
  libgcc libstdc++ libaio
  nss-softokn-freebl perl-Net-Ping.noarch
  bc lsof net-tools
  ed
  unzip chkconfig
)
install_best_effort "Paquetes base unificados" "${PKGS_UNIFICADOS[@]}"

# ==========================
#  GUARDIA DE CONFLICTOS OPENSSL FIPS (RHEL vs CentOS Stream)
# ==========================
echo "==> [FIPS] Revisando proveedor FIPS..."
if rpm -q openssl-fips-provider-so >/dev/null 2>&1; then
  echo "   ⚠ Detectado paquete FIPS de RHEL: openssl-fips-provider-so"
  echo "   → Intentando 'dnf swap' por el de CentOS Stream (sin quitar protegidos)..."
  # 1) Intento preferente: swap con allowerasing
  if ! dnf_cmd -y swap --allowerasing openssl-fips-provider-so openssl-fips-provider; then
    echo "   ⚠ swap (vía dnf_cmd) falló, reintento con dnf directo..."
    if ! dnf -y swap --allowerasing openssl-fips-provider-so openssl-fips-provider; then
      echo "   ⚠ swap directo falló, probando instalación explícita del proveedor FIPS de Stream..."
      # 2) Instalar el proveedor FIPS de Stream y permitir reemplazos de archivos
      if ! dnf -y install --best --allowerasing openssl-fips-provider; then
        echo "   ⚠ instalación de openssl-fips-provider falló; alineando sólo paquetes OpenSSL..."
        # 3) Alinear solo la familia OpenSSL (evita distro-sync total)
        dnf -y distro-sync --allowerasing \
           openssl openssl-libs openssl-fips-provider || true
      fi
    fi
  fi

  echo "   → Estado después del manejo FIPS:"
  rpm -q openssl-fips-provider-so || echo "   - openssl-fips-provider-so ya no está (OK)"
  rpm -q openssl-fips-provider    && echo "   - openssl-fips-provider instalado (OK)"

  # limpiamos transacción previa para evitar basura en cache
  dnf clean packages || true
fi

# ==========================
#  PAM 64/32 (directo)
# ==========================
echo "==> [PAM] Instalando pam (x86_64) y pam.i686 de forma directa..."
dnf_cmd -y --disableexcludes=all install --best --allowerasing pam pam.i686

echo "==> [PAM] Verificando RPMs instalados:"
rpm -q pam || { echo "❌ pam (x86_64) no quedó instalado"; exit 10; }
rpm -q pam.i686 || { echo "❌ pam.i686 no quedó instalado"; exit 11; }

echo "==> [PAM] Refrescando enlazador y verificando libpam.so.0..."
/sbin/ldconfig
/sbin/ldconfig -p | grep -E 'libpam\.so\.0' || echo "⚠ libpam.so.0 no aparece en caché ld (puede tardar un momento)"

echo "==> [PAM] Presencia en disco (64/32):"
ls -l /usr/lib64/libpam.so.0* 2>/dev/null || true
ls -l /usr/lib/libpam.so.0*   2>/dev/null || true

echo
echo "✅ Listo."
echo "   - Repos preparados (${OS_ID}${USE_CENTOS_REPOS:+ -> CentOS Stream 9})"
echo "   - Paquetes base instalados"
echo "   - PAM multilib instalado y verificado (rpm/ldconfig)"
echo "   * Log: ${LOG}"
