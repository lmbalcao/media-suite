#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Media Suite — Bootstrap para LXC privilegiado (Proxmox) com /dev/net/tun
# Autor: Luís Balcão — Repo: lmbalcao/media-suite
# ===============================

# ==========================================
# Passo 0: Validação do ficheiro .env
# ==========================================
echo "=== Passo 0: Validação do .env ==="

ENV_FILE="./.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Erro: ficheiro $ENV_FILE não encontrado. Cria a partir de .env.example."
  exit 1
fi

# verificar linhas com espaços depois do "="
if grep -qE '^[A-Z0-9_]+=[^#]*\s' "$ENV_FILE"; then
  echo "❌ Erro: O .env contém valores com espaços. Exemplo:"
  grep -nE '^[A-Z0-9_]+=[^#]*\s' "$ENV_FILE"
  echo "➡️ Corrige substituindo espaços por underscores (ex: private_internet_access)"
  exit 1
fi

echo "✅ .env validado com sucesso"

# ---- Helpers ----
log() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m[ERRO]\033[0m %s\n" "$*"; }
die() { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "Corre como root: sudo ./bootstrap_media.sh"; }

ensure_pkg() {
  # instala pacotes se faltarem
  local pkgs=("$@")
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
}

ensure_line() {
  # adiciona linha ao ficheiro se não existir (pela âncora do início)
  local file="$1" line="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# ======================================================================
# Passo 0) Informativo (não bloqueante)
# ======================================================================
step0_info() {
  warn "Passo 0 (informativo): Este script assume LXC privilegiado em Proxmox com /dev/net/tun."
  warn "Se ainda não configuraste o CT no host Proxmox, confirma no /etc/pve/lxc/CTID.conf:"
  cat <<'TXT'
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
  # (opcional recomendado)
  features: keyctl=1,nesting=1
TXT
  warn "Se for VM/bare metal, basta o kernel ter o módulo TUN ativo (modprobe tun)."
}

# ======================================================================
# Passo 1) Pré-requisitos: Docker + Compose + NFS tools
# ======================================================================
step1_prereqs() {
  need_root
  log "Instalar pré-requisitos (curl, sudo, nfs-common)..."
  ensure_pkg curl sudo nfs-common ca-certificates gnupg lsb-release
  if ! command -v docker >/dev/null 2>&1; then
    log "Instalar Docker Engine via script oficial..."
    curl -fsSL https://get.docker.com | sh
  else
    log "Docker já instalado."
  fi
  if ! docker compose version >/dev/null 2>&1; then
    log "Instalar plugin docker-compose..."
    ensure_pkg docker-compose-plugin
  else
    log "Docker Compose plugin já instalado."
  fi
}

# ======================================================================
# Passo 2) Ler .env e preparar montagens NFS
# ======================================================================
step2_nfs() {
  local env_file="./.env"
  if [ ! -f "$env_file" ]; then
    cp ./.env.example "$env_file" || die "Falta .env.example no repo; não consigo criar .env."
    err "Criei .env a partir do .env.example. EDITA as variáveis NFS/PIA e volta a correr o script."
    exit 1
  fi

  log "A carregar variáveis do .env..."
  # shellcheck disable=SC2046
  set -a; . "$env_file"; set +a

  # Variáveis obrigatórias do passo 2 (NFS)
  : "${NFS_SERVER:?Define NFS_SERVER no .env}"
  : "${NFS_MEDIA_REMOTE:?Define NFS_MEDIA_REMOTE no .env (ex: /media)}"
  : "${NFS_DOWNLOADS_REMOTE:?Define NFS_DOWNLOADS_REMOTE no .env (ex: /downloads)}"
  : "${NFS_MEDIA_MOUNT:?Define NFS_MEDIA_MOUNT no .env (ex: /mnt/media)}"
  : "${NFS_DOWNLOADS_MOUNT:?Define NFS_DOWNLOADS_MOUNT no .env (ex: /mnt/downloads)}"

  log "Criar pontos de montagem NFS..."
  mkdir -p "$NFS_MEDIA_MOUNT" "$NFS_DOWNLOADS_MOUNT"

  log "Escrever/garantir entradas em /etc/fstab..."
  local fstab="/etc/fstab"
  touch "$fstab"
  # remove entradas antigas do mesmo destino (idempotente)
  sed -i "\# ${NFS_MEDIA_MOUNT} #d" "$fstab" || true
  sed -i "\# ${NFS_DOWNLOADS_MOUNT} #d" "$fstab" || true

  ensure_line "$fstab" "${NFS_SERVER}:${NFS_MEDIA_REMOTE}     ${NFS_MEDIA_MOUNT}     nfs   vers=4.1,rsize=262144,wsize=262144,hard,noatime,_netdev   0  0"
  ensure_line "$fstab" "${NFS_SERVER}:${NFS_DOWNLOADS_REMOTE} ${NFS_DOWNLOADS_MOUNT} nfs   vers=4.1,rsize=262144,wsize=262144,hard,noatime,_netdev   0  0"

  log "Montar NFS agora (mount -a)..."
  systemctl daemon-reload
  mount -a
  df -h | grep -E "${NFS_MEDIA_MOUNT}|${NFS_DOWNLOADS_MOUNT}" || die "Falha a montar NFS. Verifica IP/path no .env."
}

# ======================================================================
# Passo 3) /opt e permissões
# ======================================================================
step3_dirs_perms() {
  log "Criar diretórios /opt e aplicar ownership 1000:1000..."
  mkdir -p /opt/{sonarr,radarr,lidarr,prowlarr,bazarr,jellyfin,rdtclient}
  mkdir -p /opt/tdarr/{server,configs,logs}
  mkdir -p /opt/gluetun
  chown -R 1000:1000 /opt/{sonarr,radarr,lidarr,prowlarr,bazarr,jellyfin,rdtclient,tdarr,gluetun}
  find /opt/{sonarr,radarr,lidarr,prowlarr,bazarr,jellyfin,rdtclient,tdarr} -type d -exec chmod g+s {} \;
}

# ======================================================================
# Passo 4) Gerar /opt/media-stack (.env + compose) a partir do repo
# ======================================================================
step4_stack_files() {
  log "Preparar /opt/media-stack..."
  mkdir -p /opt/media-stack

  # Copiar .env do repo (faz merge simples sem duplicar linhas)
  log "Sincronizar .env do repo para /opt/media-stack/.env..."
  if [ -f "./.env" ]; then
    # Mantém .env do repo como fonte da verdade
    cp ./ .env /opt/media-stack/.env
  else
    die "Falta .env ao lado do script; cria a partir do .env.example e volta a correr."
  fi

  # Criar docker-compose.yml (versão final acordada)
  log "Escrever /opt/media-stack/docker-compose.yml..."
  cat > /opt/media-stack/docker-compose.yml <<'YAML'
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    cap_add: [NET_ADMIN]
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - TZ=${TZ}
      - VPN_SERVICE_PROVIDER=${VPN_SERVICE_PROVIDER}
      - VPN_TYPE=${VPN_TYPE}
      - OPENVPN_USER=${OPENVPN_USER}
      - OPENVPN_PASSWORD=${OPENVPN_PASSWORD}
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES}
      - SERVER_REGIONS=${SERVER_REGIONS}
      - BLOCK_MALICIOUS=${BLOCK_MALICIOUS}
      - DOT=${DOT}
    volumes:
      - /opt/gluetun:/gluetun
    ports:
      - "6767:6767"   # Bazarr
      - "7878:7878"   # Radarr
      - "8989:8989"   # Sonarr
      - "8686:8686"   # Lidarr
      - "9696:9696"   # Prowlarr
      - "8096:8096"   # Jellyfin
      - "8265:8265"   # Tdarr Web
      - "8266:8266"   # Tdarr Server
      - "6500:6500"   # RDTClient
    restart: unless-stopped

  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    container_name: sonarr
    user: "${PUID}:${PGID}"
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /opt/sonarr:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    container_name: radarr
    user: "${PUID}:${PGID}"
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /opt/radarr:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  lidarr:
    image: lscr.io/linuxserver/lidarr:latest
    container_name: lidarr
    user: "${PUID}:${PGID}"
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /opt/lidarr:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: prowlarr
    user: "${PUID}:${PGID}"
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /opt/prowlarr:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  bazarr:
    image: lscr.io/linuxserver/bazarr:latest
    container_name: bazarr
    user: "${PUID}:${PGID}"
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - /opt/bazarr:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    container_name: jellyfin
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/jellyfin:/config
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  tdarr:
    image: ghcr.io/haveagitgat/tdarr:latest
    container_name: tdarr
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - TZ=${TZ}
      - serverIP=${TDARR_SERVER_IP}
      - serverPort=${TDARR_SERVER_PORT}
      - webUIPort=${TDARR_WEBUI_PORT}
      - internalNode=${TDARR_INTERNAL_NODE}
      - nodeIP=${TDARR_NODE_IP}
      - nodePort=${TDARR_NODE_PORT}
      - nodeName=${TDARR_NODE_NAME}
    volumes:
      - /opt/tdarr/server:/app/server
      - /opt/tdarr/configs:/app/configs
      - /opt/tdarr/logs:/app/logs
      - ${NFS_MEDIA_MOUNT}:/media
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped

  rdtclient:
    image: ghcr.io/rogerfar/rdtclient:latest
    container_name: rdtclient
    network_mode: "service:gluetun"
    depends_on: [gluetun]
    environment:
      - TZ=${TZ}
    volumes:
      - /opt/rdtclient:/config
      - ${NFS_DOWNLOADS_MOUNT}:/downloads
    restart: unless-stopped
    
 ombi:
  image: lscr.io/linuxserver/ombi:latest
  container_name: ombi
  user: "${PUID}:${PGID}"
  network_mode: "service:gluetun"   # usa a rede do gluetun
  depends_on: [gluetun]
  environment:
    - PUID=${PUID}
    - PGID=${PGID}
    - TZ=${TZ}
  volumes:
    - /opt/ombi:/config
    # (opcional) só se quiseres dar browse a paths locais:
    # - ${NFS_MEDIA_MOUNT}:/media:ro
    # - ${NFS_DOWNLOADS_MOUNT}:/downloads:ro
  restart: unless-stopped
  # Nota: como está em "service:gluetun", expõe a porta no próprio gluetun:
  # adiciona "3579" em FIREWALL_VPN_INPUT_PORTS no serviço gluetun.
YAML

  log "Validar sintaxe do compose..."
  (cd /opt/media-stack && docker compose config >/dev/null) || die "docker-compose.yml inválido."
}

# ======================================================================
# Passo 5) Subir stack + health-checks
# ======================================================================
step5_up_checks() {
  log "Pull & Up do stack..."
  (cd /opt/media-stack && docker compose pull)
  (cd /opt/media-stack && docker compose up -d)
  (cd /opt/media-stack && docker compose ps)

  log "Verificar Gluetun (health & IP público PIA)..."
  (cd /opt/media-stack && docker inspect --format '{{.State.Health.Status}}' gluetun || true)
  (cd /opt/media-stack && docker logs --tail=60 gluetun || true)
  (cd /opt/media-stack && docker exec gluetun sh -lc 'wget -qO- https://ipinfo.io/ip || wget -qO- https://ifconfig.me' || true)

  log "Testar UIs locais (HTTP HEAD via portas expostas no Gluetun)..."
  for p in 8989 7878 8686 9696 6767 8096 8265 6500; do
    printf -- "  %s: " "$p"
    curl -sI "http://127.0.0.1:$p" | head -n1 || true
  done
}

# ======================================================================
# Execução
# ======================================================================
step0_info
step1_prereqs
step2_nfs
step3_dirs_perms
step4_stack_files
step5_up_checks

log "✅ Media Suite instalada/atualizada. Cria DNS internos (APP.lbtec.org → IP do host) conforme portas."
