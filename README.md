# 🎬 Media Suite (em testes)

Automatização de um stack multimédia com Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Jellyfin, Tdarr e RdtClient, todos encapsulados atrás do Gluetun (VPN).

---

## 📋 Requisitos

- 🌐 Provedor VPN **suportado pelo [Gluetun](https://github.com/qdm12/gluetun)**
- ⚙️ Device `/dev/net/tun` disponível no host/LXC
- 📂 Acesso **NFS** configurado e permitido
- 👤 Permissões de NFS compatíveis com **UID/GID definidos no `.env`**

---

## 🚀 Passos de Instalação

```bash
# 1. Atualizar pacotes
sudo apt update

# 2. Instalar dependências
sudo apt install -y sudo git

# 3. Clonar o repositório
cd /opt
git clone https://github.com/lmbalcao/media-suite.git
cd media-suite

# 4. Preparar ficheiro de configuração
cp .env.example .env
nano .env   # editar com credenciais VPN e paths NFS

# 5. Correr o bootstrap
sudo ./bootstrap_media.sh
