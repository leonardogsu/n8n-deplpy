#!/bin/bash

#############################################
# Script de Instalación Automática de n8n
# Con Docker, PostgreSQL, MySQL, SSL y Backup
# Para Ubuntu 24.04 LTS (VM Proxmox / KVM)
#############################################

set -e  # Salir si hay algún error

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

# Función para imprimir mensajes
print_message() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# Banner
echo -e "${BLUE}"
cat << "EOF"
╔═══════════════════════════════════════════╗
║   Instalador Automático de n8n           ║
║   Docker + PostgreSQL + MySQL + SSL       ║
╚═══════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Verificar que se ejecuta como root o con sudo
if [[ $EUID -ne 0 ]]; then
   print_error "Este script debe ejecutarse como root o con sudo"
   exit 1
fi

# Verificar Ubuntu 24.04
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        print_error "Este script está diseñado para Ubuntu. SO detectado: $ID"
        exit 1
    fi
    if [[ "$VERSION_ID" != "24.04" ]]; then
        print_warning "Este script está optimizado para Ubuntu 24.04 LTS"
        print_warning "Versión detectada: $VERSION_ID — pueden haber incompatibilidades"
        read -p "¿Continuar de todos modos? (s/n): " FORCE_CONTINUE
        if [[ ! "$FORCE_CONTINUE" =~ ^[sS]$ ]]; then
            exit 0
        fi
    fi
    print_message "Ubuntu $VERSION_ID detectado"
else
    print_warning "No se pudo detectar la versión del SO"
fi

# Obtener el usuario real (no root)
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Solicitar información al usuario
print_info "Configuración inicial"
echo ""

read -p "Ingresa tu dominio (ej: n8n.tudominio.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    print_error "El dominio no puede estar vacío"
    read -p "Ingresa tu dominio: " DOMAIN
done

# =============================================
# OPCIONES SSL (MEJORA 8: SSL opcional)
# =============================================
echo ""
read -p "¿Deseas instalar SSL con Let's Encrypt? (s/n): " INSTALL_SSL
if [[ "$INSTALL_SSL" =~ ^[sS]$ ]]; then
    INSTALL_SSL="yes"

    read -p "Ingresa tu email para SSL (Let's Encrypt): " EMAIL
    while [[ -z "$EMAIL" ]]; do
        print_error "El email no puede estar vacío"
        read -p "Ingresa tu email: " EMAIL
    done

    read -p "¿Bloquear puerto 80 hasta que SSL esté listo? (s/n): " BLOCK_80
    if [[ "$BLOCK_80" =~ ^[sS]$ ]]; then
        BLOCK_80="yes"
    else
        BLOCK_80="no"
    fi
else
    INSTALL_SSL="no"
    BLOCK_80="no"
    EMAIL="noreply@${DOMAIN}"
    print_warning "SSL no se instalará. n8n funcionará por HTTP en puerto 80."
    print_warning "Puedes instalar SSL después con: sudo certbot --nginx -d $DOMAIN"
fi

# Protocolo según SSL
if [[ "$INSTALL_SSL" == "yes" ]]; then
    N8N_PROTOCOL="https"
    N8N_URL="https://${DOMAIN}"
else
    N8N_PROTOCOL="http"
    N8N_URL="http://${DOMAIN}"
fi

# =============================================
# MEJORA 1 y 2: Generar TODAS las credenciales
# =============================================
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
MYSQL_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
N8N_RUNNERS_AUTH_TOKEN=$(openssl rand -hex 32)

# Configuración
N8N_DIR="$REAL_HOME/n8n"
BACKUP_DIR="$N8N_DIR/backups"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"
MYSQL_DATABASE="n8n_data"
MYSQL_USER="n8n"
TIMEZONE="Europe/Madrid"

print_info "Configuración:"
echo "  - Dominio: $DOMAIN"
echo "  - SSL: $( [[ "$INSTALL_SSL" == "yes" ]] && echo "Sí (email: $EMAIL)" || echo "No" )"
echo "  - Bloqueo puerto 80: $( [[ "$BLOCK_80" == "yes" ]] && echo "Sí" || echo "No" )"
echo "  - Directorio: $N8N_DIR"
echo "  - Zona horaria: $TIMEZONE"
echo ""

read -p "¿Deseas continuar? (s/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    print_error "Instalación cancelada"
    exit 0
fi

#############################################
# 1. CONFIGURAR SWAP (MEJORA 5)
#############################################
print_message "Configurando swap de 2GB..."

if [ -f /swapfile ] && swapon --show | grep -q '/swapfile'; then
    SWAP_OK=true
    print_warning "Ya existe un swapfile activo, omitiendo..."
else
    # Intentar crear swap (puede fallar en OpenVZ/LXC)
    SWAP_OK=false
    if fallocate -l 2G /swapfile 2>/dev/null && \
       chmod 600 /swapfile && \
       mkswap /swapfile 2>/dev/null && \
       swapon /swapfile 2>/dev/null; then
        SWAP_OK=true

        # Hacer persistente
        if ! grep -q '/swapfile' /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi

        # Optimizar swappiness para servidor
        sysctl vm.swappiness=10 2>/dev/null || true
        if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
            echo 'vm.swappiness=10' >> /etc/sysctl.conf
        fi

        print_message "Swap de 2GB configurado"
    else
        # Limpiar si falló a mitad
        rm -f /swapfile 2>/dev/null
        print_warning "No se pudo crear swap (VPS con OpenVZ/LXC no lo permite)"
        print_warning "Con 2GB sin swap, vigila el uso de memoria: free -h"
    fi
fi

#############################################
# 2. ACTUALIZAR SISTEMA
#############################################
print_message "Actualizando sistema..."
apt update && apt upgrade -y

#############################################
# 3. INSTALAR DEPENDENCIAS
#############################################
print_message "Instalando dependencias..."
apt install -y \
    ca-certificates \
    curl \
    wget \
    git \
    gnupg \
    lsb-release \
    ufw \
    nginx \
    gettext-base \
    logrotate \
    apt-transport-https \
    snapd

#############################################
# 4. INSTALAR DOCKER (repositorio oficial para Ubuntu 24.04)
#############################################
print_message "Instalando Docker..."

if ! command -v docker &> /dev/null; then
    # Eliminar paquetes conflictivos de Docker
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
        apt remove -y $pkg 2>/dev/null || true
    done

    # Añadir clave GPG oficial de Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Añadir repositorio de Docker para Ubuntu 24.04 (noble)
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update

    # Instalar Docker CE + Compose plugin
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Agregar usuario al grupo docker
    usermod -aG docker "$REAL_USER"

    # Habilitar Docker
    systemctl enable docker
    systemctl start docker

    print_message "Docker CE instalado con docker compose v2"
else
    print_warning "Docker ya está instalado"
    # Asegurar que el plugin compose está presente
    if ! docker compose version &> /dev/null; then
        print_info "Instalando plugin docker-compose-plugin..."
        apt install -y docker-compose-plugin
    fi
fi

print_message "Docker: $(docker --version)"
print_message "Compose: $(docker compose version --short)"

#############################################
# 5. CREAR ESTRUCTURA DE DIRECTORIOS (MEJORA 3)
#############################################
print_message "Creando directorios..."

mkdir -p "$N8N_DIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "$N8N_DIR/n8n-data"
mkdir -p "$N8N_DIR/postgres-data"
mkdir -p "$N8N_DIR/mysql-data"
mkdir -p "$N8N_DIR/mysql-init"

# Cambiar propietario
chown -R "$REAL_USER":"$REAL_USER" "$N8N_DIR"

#############################################
# 6. CREAR DOCKER-COMPOSE DESDE TEMPLATE
#############################################
print_message "Creando configuración de Docker Compose desde template..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/docker-compose.yml.template" ]; then
    print_error "No se encontró el archivo docker-compose.yml.template"
    print_error "Asegúrate de tener el archivo en el mismo directorio que el script"
    exit 1
fi

# Exportar TODAS las variables para envsubst (MEJORA 1 y 2)
export POSTGRES_USER
export POSTGRES_PASSWORD
export POSTGRES_DB
export DOMAIN
export TIMEZONE
export MYSQL_ROOT_PASSWORD
export MYSQL_DATABASE
export MYSQL_USER
export MYSQL_PASSWORD
export N8N_RUNNERS_AUTH_TOKEN
export N8N_PROTOCOL

# Generar docker-compose.yml desde template
envsubst < "$SCRIPT_DIR/docker-compose.yml.template" > "$N8N_DIR/docker-compose.yml"

chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/docker-compose.yml"

print_message "docker-compose.yml generado desde template"

#############################################
# 7. GUARDAR CREDENCIALES (MEJORA 6: no imprimir en terminal)
#############################################
print_message "Guardando credenciales..."

cat > "$N8N_DIR/.env" << EOF
# Credenciales de n8n
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}

# PostgreSQL
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}

# MySQL
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}

# n8n Task Runners
N8N_RUNNERS_AUTH_TOKEN=${N8N_RUNNERS_AUTH_TOKEN}

# General
TIMEZONE=${TIMEZONE}
N8N_PROTOCOL=${N8N_PROTOCOL}
INSTALL_SSL=${INSTALL_SSL}

# Generado el: $(date)
EOF

chmod 600 "$N8N_DIR/.env"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/.env"

#############################################
# 8. CONFIGURAR FIREWALL
#############################################
print_message "Configurando firewall..."

ufw --force enable
ufw allow 22/tcp
ufw allow 443/tcp

if [[ "$INSTALL_SSL" == "yes" && "$BLOCK_80" == "yes" ]]; then
    # Puerto 80 se abre temporalmente solo para Certbot
    print_message "Firewall configurado (puertos 22, 443) - Puerto 80 bloqueado hasta SSL"
else
    ufw allow 80/tcp
    print_message "Firewall configurado (puertos 22, 80, 443)"
fi

#############################################
# 9. INICIAR N8N
#############################################
print_message "Iniciando contenedores de n8n..."

cd "$N8N_DIR"
sudo -u "$REAL_USER" docker compose up -d

# Esperar a que PostgreSQL esté listo
print_info "Esperando a que PostgreSQL esté listo..."
for i in {1..45}; do
    if docker exec n8n-postgres pg_isready -U n8n > /dev/null 2>&1; then
        print_message "PostgreSQL está listo"
        break
    fi
    if [ $i -eq 45 ]; then
        print_warning "PostgreSQL tardó más de lo esperado, pero continuando..."
    fi
    sleep 1
done

# Esperar a que MySQL esté listo
print_info "Esperando a que MySQL esté listo..."
for i in {1..45}; do
    if docker exec n8n-mysql mysqladmin ping -h localhost -u root -p"${MYSQL_ROOT_PASSWORD}" --silent > /dev/null 2>&1; then
        print_message "MySQL está listo"
        break
    fi
    if [ $i -eq 45 ]; then
        print_warning "MySQL tardó más de lo esperado, pero continuando..."
    fi
    sleep 1
done

# Esperar a que n8n esté listo
print_info "Esperando a que n8n esté listo..."
sleep 10

#############################################
# 10. CONFIGURAR SSL Y NGINX
#############################################

if [[ "$INSTALL_SSL" == "yes" ]]; then
    # =========================================
    # 10a. INSTALAR CERTBOT VIA SNAP (Ubuntu 24.04)
    # =========================================
    print_message "Instalando Certbot vía snap..."

    # Eliminar certbot de apt si existe
    apt remove -y certbot python3-certbot-nginx 2>/dev/null || true

    # Instalar via snap (recomendado por Let's Encrypt para Ubuntu 24.04)
    snap install --classic certbot 2>/dev/null || true
    ln -sf /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true

    # Instalar plugin nginx para certbot
    snap set certbot trust-plugin-with-root=ok 2>/dev/null || true
    snap install certbot-nginx 2>/dev/null || true

    print_message "Certbot instalado: $(certbot --version 2>&1)"

    # =========================================
    # 10b. OBTENER CERTIFICADO SSL
    # =========================================
    print_message "Configurando SSL con Let's Encrypt..."

    print_warning "Asegúrate de que $DOMAIN apunta a la IP de este servidor"
    sleep 3

    if [[ "$BLOCK_80" == "yes" ]]; then
        # Modo seguro: certbot standalone, sin nginx expuesto en HTTP
        systemctl stop nginx 2>/dev/null || true

        # Abrir puerto 80 temporalmente para el challenge HTTP-01
        ufw allow 80/tcp

        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL"

        # Cerrar puerto 80 de nuevo
        ufw deny 80/tcp

        print_message "Certificado SSL obtenido (puerto 80 cerrado)"
    else
        # Modo permisivo: certbot con nginx ya corriendo en 80
        # Configurar nginx HTTP temporal para el challenge
        cat > /etc/nginx/sites-available/n8n << 'TMPNGINX'
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
TMPNGINX
        ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
        rm -f /etc/nginx/sites-enabled/default
        systemctl restart nginx

        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect

        print_message "Certificado SSL obtenido (nginx con certbot plugin)"
    fi

    # =========================================
    # 10c. CONFIGURAR NGINX CON SSL DESDE TEMPLATE
    # =========================================
    print_message "Configurando Nginx con SSL desde template..."

    if [ ! -f "$SCRIPT_DIR/nginx.conf.template" ]; then
        print_error "No se encontró el archivo nginx.conf.template"
        exit 1
    fi

    # Generar configuración de nginx con SSL
    envsubst '${DOMAIN}' < "$SCRIPT_DIR/nginx.conf.template" > /etc/nginx/sites-available/n8n

    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
    rm -f /etc/nginx/sites-enabled/default

    nginx -t

    # Abrir puerto 80 (solo redirige a HTTPS)
    ufw allow 80/tcp

    systemctl restart nginx

    print_message "Nginx configurado con SSL"

    # =========================================
    # 10d. RENOVACIÓN AUTOMÁTICA SSL
    # =========================================
    print_message "Configurando renovación automática de SSL..."

    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'HOOK_EOF'
#!/bin/bash
systemctl reload nginx
HOOK_EOF

    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

else
    # =========================================
    # 10e. NGINX SIN SSL (solo HTTP)
    # =========================================
    print_message "Configurando Nginx sin SSL (HTTP)..."

    cat > /etc/nginx/sites-available/n8n << HTTPNGINX
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 300;
        proxy_send_timeout 300;
        proxy_read_timeout 300;
        send_timeout 300;
    }
}
HTTPNGINX

    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
    rm -f /etc/nginx/sites-enabled/default

    nginx -t
    systemctl restart nginx

    print_message "Nginx configurado (HTTP sin SSL)"
    print_warning "Para añadir SSL después ejecuta: sudo certbot --nginx -d $DOMAIN --email TU_EMAIL"
fi

#############################################
# 13. CREAR SCRIPTS DE BACKUP Y RESTORE
#############################################
print_message "Creando scripts de backup y restore..."

# Verificar templates
for TPL in backup.sh.template restore.sh.template; do
    if [ ! -f "$SCRIPT_DIR/$TPL" ]; then
        print_error "No se encontró $TPL en $SCRIPT_DIR"
        exit 1
    fi
done

# Copiar y sustituir placeholders en backup.sh
cp "$SCRIPT_DIR/backup.sh.template" "$N8N_DIR/backup.sh"
sed -i "s|__N8N_DIR__|${N8N_DIR}|g" "$N8N_DIR/backup.sh"
sed -i "s|__BACKUP_DIR__|${BACKUP_DIR}|g" "$N8N_DIR/backup.sh"
sed -i "s|__POSTGRES_USER__|${POSTGRES_USER}|g" "$N8N_DIR/backup.sh"
sed -i "s|__POSTGRES_DB__|${POSTGRES_DB}|g" "$N8N_DIR/backup.sh"
sed -i "s|__MYSQL_ROOT_PASSWORD__|${MYSQL_ROOT_PASSWORD}|g" "$N8N_DIR/backup.sh"
chmod +x "$N8N_DIR/backup.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/backup.sh"

# Copiar y sustituir placeholders en restore.sh
cp "$SCRIPT_DIR/restore.sh.template" "$N8N_DIR/restore.sh"
sed -i "s|__N8N_DIR__|${N8N_DIR}|g" "$N8N_DIR/restore.sh"
sed -i "s|__BACKUP_DIR__|${BACKUP_DIR}|g" "$N8N_DIR/restore.sh"
sed -i "s|__POSTGRES_USER__|${POSTGRES_USER}|g" "$N8N_DIR/restore.sh"
sed -i "s|__POSTGRES_DB__|${POSTGRES_DB}|g" "$N8N_DIR/restore.sh"
sed -i "s|__MYSQL_ROOT_PASSWORD__|${MYSQL_ROOT_PASSWORD}|g" "$N8N_DIR/restore.sh"
chmod +x "$N8N_DIR/restore.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/restore.sh"

print_message "backup.sh y restore.sh configurados"

#############################################
# 14. CONFIGURAR CRON PARA BACKUP AUTOMÁTICO
#############################################
print_message "Configurando backup automático diario..."

(crontab -u "$REAL_USER" -l 2>/dev/null; echo "0 2 * * * $N8N_DIR/backup.sh --full >> $N8N_DIR/backup.log 2>&1") | crontab -u "$REAL_USER" -

#############################################
# 15. CONFIGURAR LOGROTATE (MEJORA 10)
#############################################
print_message "Configurando rotación de logs..."

cat > /etc/logrotate.d/n8n << LOGEOF
$N8N_DIR/backup.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 644 $REAL_USER $REAL_USER
}
LOGEOF

print_message "Logrotate configurado para backup.log"

#############################################
# 16. CREAR SCRIPT DE GESTIÓN (MEJORA 7: docker compose v2)
#############################################
print_message "Creando scripts de gestión..."

cat > "$N8N_DIR/n8n-manage.sh" << MGEOF
#!/bin/bash

# Script de gestión de n8n

N8N_DIR="$N8N_DIR"
cd "\$N8N_DIR"

case "\$1" in
    start)
        echo "Iniciando n8n..."
        docker compose up -d
        echo "✓ n8n iniciado"
        ;;
    stop)
        echo "Deteniendo n8n..."
        docker compose down
        echo "✓ n8n detenido"
        ;;
    restart)
        echo "Reiniciando n8n..."
        docker compose restart
        echo "✓ n8n reiniciado"
        ;;
    status)
        docker compose ps
        ;;
    logs)
        docker compose logs -f n8n
        ;;
    backup)
        shift
        ./backup.sh "\$@"
        ;;
    restore)
        shift
        ./restore.sh "\$@"
        ;;
    update)
        echo "Actualizando n8n..."
        docker compose pull
        docker compose up -d
        echo "✓ n8n actualizado"
        ;;
    *)
        echo "Uso: \$0 COMANDO [opciones]"
        echo ""
        echo "Comandos:"
        echo "  start       Iniciar n8n"
        echo "  stop        Detener n8n"
        echo "  restart     Reiniciar n8n"
        echo "  status      Ver estado de contenedores"
        echo "  logs        Ver logs en tiempo real"
        echo "  update      Actualizar n8n a última versión"
        echo "  backup      Crear backup (usa --help para opciones)"
        echo "  restore     Restaurar backup (usa --help para opciones)"
        echo ""
        echo "Ejemplos:"
        echo "  \$0 backup                        # Backup completo"
        echo "  \$0 backup --migrate              # Backup para migración"
        echo "  \$0 backup --dry-run              # Simular backup"
        echo "  \$0 restore --list                # Listar backups"
        echo "  \$0 restore archivo.tar.gz        # Restaurar backup"
        echo "  \$0 restore --migrate archivo.tar.gz  # Restaurar migración"
        exit 1
        ;;
esac
MGEOF

chmod +x "$N8N_DIR/n8n-manage.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/n8n-manage.sh"

#############################################
# 17. CREAR README
#############################################
cat > "$N8N_DIR/README.md" << EOF
# n8n - Instalación Completada

## 🌐 Acceso
- **URL**: ${N8N_URL}
- **SSL**: $( [[ "$INSTALL_SSL" == "yes" ]] && echo "Sí (Let's Encrypt, email: ${EMAIL})" || echo "No instalado" )

## 📁 Ubicaciones
- Directorio principal: \`$N8N_DIR\`
- Datos de n8n: \`$N8N_DIR/n8n-data\`
- Base de datos PostgreSQL: \`$N8N_DIR/postgres-data\`
- Base de datos MySQL: \`$N8N_DIR/mysql-data\`
- Backups: \`$BACKUP_DIR\`
- Credenciales: \`$N8N_DIR/.env\`

## 🔧 Comandos de Gestión

### Gestión básica:
\`\`\`bash
cd ~/n8n
./n8n-manage.sh start      # Iniciar n8n
./n8n-manage.sh stop       # Detener n8n
./n8n-manage.sh restart    # Reiniciar n8n
./n8n-manage.sh status     # Ver estado
./n8n-manage.sh logs       # Ver logs en tiempo real
./n8n-manage.sh update     # Actualizar n8n
\`\`\`

### Backups:
\`\`\`bash
./n8n-manage.sh backup                              # Backup completo
./n8n-manage.sh backup --migrate                    # Backup para migración (incluye JSON + encryption key)
./n8n-manage.sh backup --workflows                  # Solo exportar workflows JSON
./n8n-manage.sh backup --dry-run                    # Simular sin crear archivos
./n8n-manage.sh restore --list                      # Listar backups disponibles
./n8n-manage.sh restore --inspect archivo.tar.gz    # Ver contenido de un backup
./n8n-manage.sh restore archivo.tar.gz              # Restaurar completo
./n8n-manage.sh restore --migrate archivo.tar.gz    # Restaurar migración desde otro servidor
./n8n-manage.sh restore --workflows archivo.tar.gz  # Solo importar workflows
\`\`\`

**Backup automático**: Configurado diariamente a las 2:00 AM

## 🔐 Credenciales
Todas las credenciales están guardadas en \`$N8N_DIR/.env\`:
- PostgreSQL: usuario \`${POSTGRES_USER}\`, base de datos \`${POSTGRES_DB}\`
- MySQL: usuario \`${MYSQL_USER}\`, base de datos \`${MYSQL_DATABASE}\`
- phpMyAdmin: accesible en \`http://localhost:8080\` (solo local/SSH tunnel)

## 📊 Capacidad
- **RAM**: 2GB $( [[ "\$SWAP_OK" == "true" ]] && echo "+ 2GB swap" || echo "(sin swap)" )
- **Configuración**: suficiente para ~60-120 tareas/hora

## 🔄 SSL
$( [[ "$INSTALL_SSL" == "yes" ]] && cat << 'SSLBLOCK'
El certificado SSL se renueva automáticamente vía Certbot.
Para renovar manualmente:
\`\`\`bash
sudo certbot renew
\`\`\`
SSLBLOCK
)
$( [[ "$INSTALL_SSL" != "yes" ]] && echo "SSL no instalado. Para instalar después:" && echo "\`\`\`bash" && echo "sudo certbot --nginx -d ${DOMAIN} --email TU_EMAIL" && echo "\`\`\`" )

## 📝 Logs
\`\`\`bash
docker logs n8n -f             # Logs de n8n
docker logs n8n-postgres -f    # Logs de PostgreSQL
docker logs n8n-mysql -f       # Logs de MySQL
tail -f ~/n8n/backup.log       # Logs de backup
\`\`\`

## ⚠️ Troubleshooting
Si n8n no inicia:
\`\`\`bash
cd ~/n8n
docker compose down
docker compose up -d
docker compose logs
\`\`\`

## 🔒 Seguridad
- Firewall UFW activo (puertos 22, 80, 443)
$( [[ "$INSTALL_SSL" == "yes" ]] && echo "- SSL/TLS configurado con Let's Encrypt" || echo "- SSL no configurado (HTTP)" )
- MySQL y phpMyAdmin solo accesibles desde localhost
- Base de datos aislada en red Docker
- Contraseñas seguras generadas automáticamente
$( [[ "\$SWAP_OK" == "true" ]] && echo "- Swap de 2GB para evitar OOM kills" || echo "- Sin swap (monitorizar memoria con free -h)" )
- Rotación de logs configurada

---
Instalado el: $(date)
EOF

chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/README.md"

#############################################
# FINALIZACIÓN (MEJORA 6: no imprimir contraseñas)
#############################################

print_message "¡Instalación completada exitosamente! 🎉"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  n8n está listo para usar${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}🌐 URL:${NC} ${N8N_URL}"
if [[ "$INSTALL_SSL" == "yes" ]]; then
    echo -e "${BLUE}📧 Email SSL:${NC} ${EMAIL}"
fi
echo -e "${BLUE}📁 Directorio:${NC} ${N8N_DIR}"
echo ""
echo -e "${YELLOW}📝 Información importante:${NC}"
echo "  - Todas las credenciales guardadas en: ${N8N_DIR}/.env"
echo "  - Documentación: ${N8N_DIR}/README.md"
echo "  - Backup automático: Diario a las 2:00 AM"
echo "  - Script de gestión: ${N8N_DIR}/n8n-manage.sh"
echo "  - Swap: $( [[ "${SWAP_OK:-false}" == "true" ]] && echo "2GB configurado" || echo "no disponible (VPS no lo permite)" )"
echo "  - Logs: rotación automática configurada"
echo ""
echo -e "${YELLOW}🔧 Comandos útiles:${NC}"
echo "  cd ~/n8n"
echo "  ./n8n-manage.sh status    # Ver estado"
echo "  ./n8n-manage.sh logs      # Ver logs"
echo "  ./n8n-manage.sh backup    # Crear backup"
echo ""
echo -e "${GREEN}✓ Accede a n8n en: ${N8N_URL}${NC}"
echo ""

if [[ "$INSTALL_SSL" != "yes" ]]; then
    print_warning "SSL no instalado. Para añadirlo después:"
    echo "  sudo certbot --nginx -d $DOMAIN --email TU_EMAIL"
    echo ""
fi

print_info "Si necesitas reiniciar la sesión para que Docker funcione sin sudo:"
echo "  logout o su - $REAL_USER"
echo ""

# Verificar estado de los contenedores
print_info "Estado actual de los contenedores:"
cd "$N8N_DIR"
sudo -u "$REAL_USER" docker compose ps

exit 0
