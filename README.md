# media-suite (em testes)

Requisitos:
- Provedor VPN suportado por Gluetun
- /dev/net/tun disponível
- Acesso NFS permitido
- Permissões NFS = Permissões ID UID

Passos:
- sudo apt update
- sudo apt install -y sudo git
- cd /opt
- git clone https://github.com/lmbalcao/media-suite.git
- cd media-suite
- cp .env.example .env
- nano .env
- sudo ./bootstrap_media.sh


