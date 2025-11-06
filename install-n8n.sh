#!/bin/bash

#############################################
# Script de Instalación Automática de n8n
# Con Docker, PostgreSQL, SSL y Backup
# Para Ubuntu 25 con 2GB RAM
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
║   Docker + PostgreSQL + SSL + Backup      ║
╚═══════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Verificar que se ejecuta como root o con sudo
if [[ $EUID -ne 0 ]]; then
   print_error "Este script debe ejecutarse como root o con sudo"
   exit 1
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

read -p "Ingresa tu email para SSL (Let's Encrypt): " EMAIL
while [[ -z "$EMAIL" ]]; do
    print_error "El email no puede estar vacío"
    read -p "Ingresa tu email: " EMAIL
done

# Generar contraseña segura para PostgreSQL
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)

# Configuración
N8N_DIR="$REAL_HOME/n8n"
BACKUP_DIR="$N8N_DIR/backups"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"
TIMEZONE="Europe/Madrid"

print_info "Configuración:"
echo "  - Dominio: $DOMAIN"
echo "  - Email: $EMAIL"
echo "  - Directorio: $N8N_DIR"
echo "  - Zona horaria: $TIMEZONE"
echo ""

read -p "¿Deseas continuar? (s/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    print_error "Instalación cancelada"
    exit 0
fi

#############################################
# 1. ACTUALIZAR SISTEMA
#############################################
print_message "Actualizando sistema..."
apt update && apt upgrade -y

#############################################
# 2. INSTALAR DEPENDENCIAS
#############################################
print_message "Instalando dependencias..."
apt install -y curl wget git ufw nginx certbot python3-certbot-nginx gettext-base

#############################################
# 3. INSTALAR DOCKER
#############################################
print_message "Instalando Docker..."

if ! command -v docker &> /dev/null; then
    # Instalar Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh

    # Agregar usuario al grupo docker
    usermod -aG docker "$REAL_USER"

    # Habilitar Docker
    systemctl enable docker
    systemctl start docker

    print_message "Docker instalado correctamente"
else
    print_warning "Docker ya está instalado"
fi

# Instalar Docker Compose
if ! command -v docker-compose &> /dev/null; then
    apt install -y docker-compose
    print_message "Docker Compose instalado"
else
    print_warning "Docker Compose ya está instalado"
fi

#############################################
# 4. CREAR ESTRUCTURA DE DIRECTORIOS
#############################################
print_message "Creando directorios..."

mkdir -p "$N8N_DIR"
mkdir -p "$BACKUP_DIR"
mkdir -p "$N8N_DIR/n8n-data"
mkdir -p "$N8N_DIR/postgres-data"

# Cambiar propietario
chown -R "$REAL_USER":"$REAL_USER" "$N8N_DIR"

#############################################
# 5. CREAR DOCKER-COMPOSE DESDE TEMPLATE
#############################################
print_message "Creando configuración de Docker Compose desde template..."

# Obtener el directorio del script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verificar que existe el template
if [ ! -f "$SCRIPT_DIR/docker-compose.yml.template" ]; then
    print_error "No se encontró el archivo docker-compose.yml.template"
    print_error "Asegúrate de tener el archivo en el mismo directorio que el script"
    exit 1
fi

# Exportar variables para envsubst
export POSTGRES_USER
export POSTGRES_PASSWORD
export POSTGRES_DB
export DOMAIN
export TIMEZONE

# Generar docker-compose.yml desde template
envsubst < "$SCRIPT_DIR/docker-compose.yml.template" > "$N8N_DIR/docker-compose.yml"

chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/docker-compose.yml"

print_message "docker-compose.yml generado desde template"

#############################################
# 6. GUARDAR CREDENCIALES
#############################################
print_message "Guardando credenciales..."

cat > "$N8N_DIR/.env" << EOF
# Credenciales de n8n
DOMAIN=${DOMAIN}
EMAIL=${EMAIL}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=${POSTGRES_DB}
TIMEZONE=${TIMEZONE}

# Generado el: $(date)
EOF

chmod 600 "$N8N_DIR/.env"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/.env"

#############################################
# 7. CONFIGURAR NGINX DESDE TEMPLATE
#############################################
print_message "Configurando Nginx desde template..."

# Verificar que existe el template
if [ ! -f "$SCRIPT_DIR/nginx.conf.template" ]; then
    print_error "No se encontró el archivo nginx.conf.template"
    exit 1
fi

# Generar configuración de nginx desde template
envsubst '${DOMAIN}' < "$SCRIPT_DIR/nginx.conf.template" > /etc/nginx/sites-available/n8n

# Habilitar sitio
ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n
rm -f /etc/nginx/sites-enabled/default

# Verificar configuración
nginx -t

# Reiniciar Nginx
systemctl restart nginx

print_message "Nginx configurado correctamente"

#############################################
# 8. CONFIGURAR FIREWALL
#############################################
print_message "Configurando firewall..."

ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

print_message "Firewall configurado"

#############################################
# 9. INICIAR N8N
#############################################
print_message "Iniciando contenedores de n8n..."

cd "$N8N_DIR"
sudo -u "$REAL_USER" docker-compose up -d

# Esperar a que los servicios estén listos
print_info "Esperando a que PostgreSQL esté listo..."
sleep 15

# Verificar estado de PostgreSQL
print_info "Verificando estado de PostgreSQL..."
for i in {1..30}; do
    if docker exec n8n-postgres pg_isready -U n8n > /dev/null 2>&1; then
        print_message "PostgreSQL está listo"
        break
    fi
    if [ $i -eq 30 ]; then
        print_warning "PostgreSQL tardó más de lo esperado, pero continuando..."
    fi
    sleep 1
done

# Esperar a que n8n esté listo
print_info "Esperando a que n8n esté listo..."
sleep 10

#############################################
# 10. CONFIGURAR SSL CON CERTBOT
#############################################
print_message "Configurando SSL con Let's Encrypt..."

# Verificar que el dominio apunta a este servidor
print_warning "Asegúrate de que $DOMAIN apunta a la IP de este servidor"
sleep 3

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --email "$EMAIL" --redirect

#############################################
# 11. CREAR SCRIPTS DE BACKUP
#############################################
print_message "Creando scripts de backup..."

# Script de backup
cat > "$N8N_DIR/backup.sh" << 'EOF'
#!/bin/bash

# Script de Backup para n8n

BACKUP_DIR="$HOME/n8n/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="n8n_backup_${TIMESTAMP}"

echo "Iniciando backup de n8n..."

# Crear directorio de backup
mkdir -p "${BACKUP_DIR}/${BACKUP_NAME}"

# Backup de PostgreSQL
echo "Respaldando base de datos PostgreSQL..."
docker exec n8n-postgres pg_dump -U n8n n8n > "${BACKUP_DIR}/${BACKUP_NAME}/database.sql"

# Backup de archivos de n8n
echo "Respaldando archivos de n8n..."
cp -r "$HOME/n8n/n8n-data" "${BACKUP_DIR}/${BACKUP_NAME}/"

# Backup de configuración
cp "$HOME/n8n/docker-compose.yml" "${BACKUP_DIR}/${BACKUP_NAME}/"
cp "$HOME/n8n/.env" "${BACKUP_DIR}/${BACKUP_NAME}/"

# Comprimir backup
echo "Comprimiendo backup..."
cd "$BACKUP_DIR"
tar -czf "${BACKUP_NAME}.tar.gz" "${BACKUP_NAME}"
rm -rf "${BACKUP_NAME}"

echo "✓ Backup completado: ${BACKUP_DIR}/${BACKUP_NAME}.tar.gz"

# Limpiar backups antiguos (mantener últimos 7 días)
find "$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -mtime +7 -delete
echo "✓ Backups antiguos eliminados (>7 días)"
EOF

chmod +x "$N8N_DIR/backup.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/backup.sh"

# Script de restore
cat > "$N8N_DIR/restore.sh" << 'EOF'
#!/bin/bash

# Script de Restore para n8n

if [ -z "$1" ]; then
    echo "Uso: ./restore.sh <archivo_backup.tar.gz>"
    echo "Backups disponibles:"
    ls -lh "$HOME/n8n/backups/"*.tar.gz 2>/dev/null || echo "No hay backups disponibles"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: El archivo $BACKUP_FILE no existe"
    exit 1
fi

echo "⚠️  ADVERTENCIA: Este proceso detendrá n8n y restaurará desde el backup"
read -p "¿Deseas continuar? (s/n): " CONFIRM

if [[ ! "$CONFIRM" =~ ^[sS]$ ]]; then
    echo "Restore cancelado"
    exit 0
fi

# Detener contenedores
echo "Deteniendo contenedores..."
cd "$HOME/n8n"
docker-compose down

# Extraer backup
TEMP_DIR=$(mktemp -d)
echo "Extrayendo backup..."
tar -xzf "$BACKUP_FILE" -C "$TEMP_DIR"
BACKUP_NAME=$(ls "$TEMP_DIR")

# Restaurar base de datos
echo "Restaurando base de datos..."
docker-compose up -d postgres
sleep 5
cat "${TEMP_DIR}/${BACKUP_NAME}/database.sql" | docker exec -i n8n-postgres psql -U n8n -d n8n

# Restaurar archivos de n8n
echo "Restaurando archivos de n8n..."
rm -rf "$HOME/n8n/n8n-data"
cp -r "${TEMP_DIR}/${BACKUP_NAME}/n8n-data" "$HOME/n8n/"

# Limpiar
rm -rf "$TEMP_DIR"

# Reiniciar contenedores
echo "Reiniciando contenedores..."
docker-compose up -d

echo "✓ Restore completado exitosamente"
EOF

chmod +x "$N8N_DIR/restore.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/restore.sh"

#############################################
# 12. CONFIGURAR CRON PARA BACKUP AUTOMÁTICO
#############################################
print_message "Configurando backup automático diario..."

# Backup diario a las 2 AM
(crontab -u "$REAL_USER" -l 2>/dev/null; echo "0 2 * * * $N8N_DIR/backup.sh >> $N8N_DIR/backup.log 2>&1") | crontab -u "$REAL_USER" -

#############################################
# 13. CREAR SCRIPT DE GESTIÓN
#############################################
print_message "Creando scripts de gestión..."

cat > "$N8N_DIR/n8n-manage.sh" << 'EOF'
#!/bin/bash

# Script de gestión de n8n

cd "$HOME/n8n"

case "$1" in
    start)
        echo "Iniciando n8n..."
        docker-compose up -d
        echo "✓ n8n iniciado"
        ;;
    stop)
        echo "Deteniendo n8n..."
        docker-compose down
        echo "✓ n8n detenido"
        ;;
    restart)
        echo "Reiniciando n8n..."
        docker-compose restart
        echo "✓ n8n reiniciado"
        ;;
    status)
        docker-compose ps
        ;;
    logs)
        docker-compose logs -f n8n
        ;;
    backup)
        ./backup.sh
        ;;
    restore)
        ./restore.sh "$2"
        ;;
    update)
        echo "Actualizando n8n..."
        docker-compose pull
        docker-compose up -d
        echo "✓ n8n actualizado"
        ;;
    *)
        echo "Uso: $0 {start|stop|restart|status|logs|backup|restore|update}"
        exit 1
        ;;
esac
EOF

chmod +x "$N8N_DIR/n8n-manage.sh"
chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/n8n-manage.sh"

#############################################
# 14. CREAR README
#############################################
cat > "$N8N_DIR/README.md" << EOF
# n8n - Instalación Completada

## 🌐 Acceso
- **URL**: https://${DOMAIN}
- **Email SSL**: ${EMAIL}

## 📁 Ubicaciones
- Directorio principal: \`$N8N_DIR\`
- Datos de n8n: \`$N8N_DIR/n8n-data\`
- Base de datos: \`$N8N_DIR/postgres-data\`
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
./n8n-manage.sh backup                      # Crear backup manual
./n8n-manage.sh restore backup_file.tar.gz  # Restaurar desde backup
\`\`\`

**Backup automático**: Configurado diariamente a las 2:00 AM

## 🔐 Credenciales de Base de Datos
Usuario: ${POSTGRES_USER}
Contraseña: Guardada en \`.env\`
Base de datos: ${POSTGRES_DB}

## 📊 Capacidad
- **RAM**: 2GB (suficiente para ~60-120 tareas/hora)
- **Configuración actual**: 1 tarea por minuto = 60 tareas/hora ✓

## 🔄 Actualización de SSL
El certificado SSL se renueva automáticamente. Para renovar manualmente:
\`\`\`bash
sudo certbot renew
\`\`\`

## 📝 Logs
\`\`\`bash
# Logs de n8n
docker logs n8n -f

# Logs de PostgreSQL
docker logs n8n-postgres -f

# Logs de backup
tail -f ~/n8n/backup.log
\`\`\`

## ⚠️ Troubleshooting
Si n8n no inicia:
\`\`\`bash
cd ~/n8n
docker-compose down
docker-compose up -d
docker-compose logs
\`\`\`

## 🔒 Seguridad
- Firewall UFW activo (puertos 22, 80, 443)
- SSL/TLS configurado con Let's Encrypt
- Base de datos aislada en red Docker
- Contraseñas seguras generadas automáticamente

---
Instalado el: $(date)
EOF

chown "$REAL_USER":"$REAL_USER" "$N8N_DIR/README.md"

#############################################
# FINALIZACIÓN
#############################################

print_message "¡Instalación completada exitosamente! 🎉"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  n8n está listo para usar${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}🌐 URL:${NC} https://${DOMAIN}"
echo -e "${BLUE}📧 Email SSL:${NC} ${EMAIL}"
echo -e "${BLUE}📁 Directorio:${NC} ${N8N_DIR}"
echo ""
echo -e "${YELLOW}📝 Información importante:${NC}"
echo "  - Credenciales guardadas en: ${N8N_DIR}/.env"
echo "  - Documentación: ${N8N_DIR}/README.md"
echo "  - Backup automático: Diario a las 2:00 AM"
echo "  - Script de gestión: ${N8N_DIR}/n8n-manage.sh"
echo ""
echo -e "${YELLOW}🔧 Comandos útiles:${NC}"
echo "  cd ~/n8n"
echo "  ./n8n-manage.sh status    # Ver estado"
echo "  ./n8n-manage.sh logs      # Ver logs"
echo "  ./n8n-manage.sh backup    # Crear backup"
echo ""
echo -e "${GREEN}✓ Accede a n8n en: https://${DOMAIN}${NC}"
echo ""

# Mostrar contraseña de la base de datos
print_warning "IMPORTANTE: Guarda esta contraseña de PostgreSQL:"
echo -e "${YELLOW}${DB_PASSWORD}${NC}"
echo ""
echo "También está guardada en: ${N8N_DIR}/.env"
echo ""

print_info "Si necesitas reiniciar la sesión para que Docker funcione sin sudo:"
echo "  logout o su - $REAL_USER"
echo ""

# Verificar estado de los contenedores
print_info "Estado actual de los contenedores:"
cd "$N8N_DIR"
sudo -u "$REAL_USER" docker-compose ps

exit 0