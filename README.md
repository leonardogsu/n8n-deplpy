# n8n — Kit de Instalación Automatizada

Instalador automatizado de [n8n](https://n8n.io) sobre Docker para **Ubuntu 24.04 LTS** en VM Proxmox / KVM. Incluye PostgreSQL, MySQL, Nginx como reverse proxy, SSL con Let's Encrypt, backups con migración, y scripts de gestión.

---

## Arquitectura

```
Internet
   │
   ▼
┌──────────────────────────┐
│  Nginx (reverse proxy)   │  :80 (redirige) / :443 (SSL)
└────────────┬─────────────┘
             │ proxy_pass :5678
             ▼
┌──────────────────────────────────────────────────────┐
│  Docker network: n8n-network                         │
│                                                      │
│  ┌──────────┐  ┌───────────┐  ┌──────────────────┐  │
│  │   n8n    │  │ PostgreSQL│  │   MySQL 8.0      │  │
│  │  :5678   │  │   :5432   │  │  :3306 (local)   │  │
│  └────┬─────┘  └───────────┘  └──────────────────┘  │
│       │                                              │
│  ┌────┴─────┐                 ┌──────────────────┐  │
│  │ n8n-     │                 │   phpMyAdmin      │  │
│  │ runner   │                 │  :8080 (local)    │  │
│  └──────────┘                 └──────────────────┘  │
└──────────────────────────────────────────────────────┘
```

**5 contenedores:** n8n (app principal), n8n-runner (ejecución de código JS/Python), PostgreSQL 15 (BD de n8n), MySQL 8.0 (para workflows), phpMyAdmin (gestión MySQL, solo local).

---

## Requisitos

| Componente | Mínimo | Recomendado |
|---|---|---|
| SO | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Virtualización | KVM (VM en Proxmox) | KVM |
| RAM | 2 GB | 3 GB |
| CPU | 1 vCPU | 2 vCPU |
| Disco | 20 GB | 30 GB |
| Red | IP pública, puerto 80 y 443 abiertos | — |
| DNS | Registro A apuntando al servidor | — |

> **Nota:** No usar contenedores LXC/OpenVZ — no permiten swap ni Docker nativo.

---

## Archivos del Kit

```
├── install-n8n.sh               # Instalador principal
├── docker-compose.yml.template  # Plantilla de servicios Docker
├── nginx.conf.template          # Plantilla de Nginx con SSL
├── backup.sh.template           # Plantilla de backup (4 modos)
├── restore.sh.template          # Plantilla de restore (6 modos)
└── clean.sh                     # Limpieza de Docker (independiente)
```

---

## Instalación

### 1. Preparar la VM

Crear una VM en Proxmox con Ubuntu 24.04 Server. Conectar por SSH.

### 2. Subir archivos

```bash
# Desde tu máquina local
scp install-n8n.sh docker-compose.yml.template nginx.conf.template \
    backup.sh.template restore.sh.template \
    usuario@servidor:/home/files/
```

### 3. Ejecutar

```bash
ssh usuario@servidor
cd /home/files
chmod +x install-n8n.sh
sudo ./install-n8n.sh
```

### 4. Preguntas interactivas

El instalador solicita:

| Pregunta | Ejemplo | Notas |
|---|---|---|
| Dominio | `n8n.tudominio.com` | Debe tener DNS apuntando al servidor |
| ¿Instalar SSL? | `s` o `n` | Con Let's Encrypt, o HTTP puro |
| Email para SSL | `tu@email.com` | Solo si SSL = sí |
| ¿Bloquear puerto 80? | `s` o `n` | Bloquea HTTP hasta que SSL esté listo |

### 5. Qué hace el instalador

1. Verifica Ubuntu 24.04
2. Crea swap de 2 GB (si la VM lo permite)
3. Actualiza el sistema
4. Instala dependencias (nginx, ufw, snapd, etc.)
5. Instala Docker CE desde repositorio oficial + Compose v2
6. Crea estructura de directorios en `~/n8n`
7. Genera `docker-compose.yml` desde template con credenciales
8. Genera credenciales seguras (PostgreSQL, MySQL, runner token)
9. Configura firewall UFW (puertos 22, 80, 443)
10. Levanta los contenedores
11. Instala Certbot vía snap y obtiene certificado SSL (si se eligió)
12. Configura Nginx como reverse proxy (con o sin SSL)
13. Instala `backup.sh` y `restore.sh` con credenciales inyectadas
14. Configura cron para backup diario a las 2:00 AM
15. Configura logrotate para rotación de logs
16. Crea `n8n-manage.sh` para gestión diaria
17. Genera README local con toda la información

---

## Gestión Diaria

Todos los comandos desde `~/n8n`:

```bash
./n8n-manage.sh start       # Iniciar todos los contenedores
./n8n-manage.sh stop        # Detener todos los contenedores
./n8n-manage.sh restart     # Reiniciar
./n8n-manage.sh status      # Ver estado
./n8n-manage.sh logs        # Logs en tiempo real de n8n
./n8n-manage.sh update      # Actualizar n8n a última versión
```

---

## Backup

El script de backup soporta 4 modos y varias opciones.

### Modos

| Modo | Comando | Contenido |
|---|---|---|
| **full** (defecto) | `./backup.sh` | PostgreSQL + MySQL + n8n-data + .env + docker-compose.yml |
| **migrate** | `./backup.sh --migrate` | Todo lo de full + workflows JSON + credenciales JSON + encryption key |
| **workflows** | `./backup.sh --workflows` | Solo workflows exportados como JSON |
| **credentials** | `./backup.sh --credentials` | Solo credenciales JSON + encryption key |

### Opciones

| Opción | Descripción |
|---|---|
| `--dry-run` | Simula el backup sin crear archivos |
| `--no-mysql` | Omite MySQL en el backup |
| `--keep N` | Retención en días (defecto: 7) |
| `--help` | Muestra ayuda |

### Verificaciones automáticas

Antes de ejecutar, backup.sh verifica: contenedores corriendo, espacio en disco (mínimo 500 MB). Después: verifica integridad del tar.gz, genera checksum SHA256, limpia backups antiguos.

### Cron automático

Configurado en la instalación: backup completo diario a las **2:00 AM**. Log en `~/n8n/backup.log` con rotación automática.

### Ejemplos

```bash
./backup.sh                              # Backup completo
./backup.sh --migrate                    # Preparar migración
./backup.sh --full --no-mysql --keep 14  # Sin MySQL, retener 14 días
./backup.sh --dry-run                    # Solo simular
```

---

## Restore

6 modos de restauración con backup de seguridad automático.

### Modos

| Modo | Comando | Qué restaura |
|---|---|---|
| **full** (defecto) | `./restore.sh archivo.tar.gz` | Todo: BD + archivos |
| **migrate** | `./restore.sh --migrate archivo.tar.gz` | Todo + encryption key + importa workflows y credenciales |
| **db-only** | `./restore.sh --db-only archivo.tar.gz` | Solo PostgreSQL y MySQL |
| **files-only** | `./restore.sh --files-only archivo.tar.gz` | Solo n8n-data |
| **workflows** | `./restore.sh --workflows archivo.tar.gz` | Solo importa workflows JSON |
| **credentials** | `./restore.sh --credentials archivo.tar.gz` | Credenciales + encryption key |

### Opciones

| Opción | Descripción |
|---|---|
| `--list` | Lista backups disponibles con tamaños |
| `--inspect archivo.tar.gz` | Muestra contenido del backup sin restaurar |
| `--no-mysql` | Omite restauración de MySQL |
| `--no-safety` | Omite backup de seguridad previo |
| `--help` | Muestra ayuda |

### Seguridad en el restore

Antes de restaurar, crea automáticamente un backup del estado actual (`n8n_pre_restore_XXXX.tar.gz`). Si algo falla, puedes revertir:

```bash
./restore.sh --no-safety n8n_pre_restore_XXXX.tar.gz
```

Después de restaurar, verifica: contenedores corriendo, n8n respondiendo en `/healthz`.

### Ejemplos

```bash
./restore.sh --list                                  # Ver backups
./restore.sh --inspect n8n_migrate_20250305.tar.gz   # Inspeccionar contenido
./restore.sh n8n_full_20250305.tar.gz                # Restaurar completo
./restore.sh --migrate n8n_migrate_20250305.tar.gz   # Migración desde otro servidor
./restore.sh --workflows n8n_migrate_20250305.tar.gz # Solo workflows
./restore.sh --db-only --no-mysql archivo.tar.gz     # Solo PostgreSQL
```

---

## Migración entre Servidores

### En el servidor origen (A)

```bash
cd ~/n8n
./backup.sh --migrate
# Genera: n8n_migrate_YYYYMMDD_HHMMSS.tar.gz
```

### Transferir al destino (B)

```bash
scp ~/n8n/backups/n8n_migrate_*.tar.gz usuario@servidorB:~/n8n/backups/
```

### En el servidor destino (B)

Primero instala n8n con `install-n8n.sh`, luego:

```bash
cd ~/n8n
./restore.sh --migrate ~/n8n/backups/n8n_migrate_YYYYMMDD_HHMMSS.tar.gz
```

Esto restaura las BD, archivos, inyecta la encryption key del servidor A en el docker-compose del servidor B, y reimporta workflows y credenciales. Las credenciales de APIs se descifran correctamente porque se migra la misma encryption key.

---

## Credenciales

Todas las credenciales se generan automáticamente durante la instalación y se guardan en `~/n8n/.env` (permisos 600). Nunca se imprimen en pantalla.

```bash
cat ~/n8n/.env    # Ver credenciales
```

Contiene: contraseñas de PostgreSQL, MySQL (root y usuario), token de autenticación del runner, dominio, email, zona horaria y protocolo.

### Encryption Key de n8n

Las credenciales de APIs de tus workflows están cifradas en PostgreSQL con una clave que n8n genera automáticamente. Se almacena en `~/n8n/n8n-data/.n8n/config`. El modo `--migrate` del backup la extrae y el restore la inyecta en el destino.

---

## SSL

### Con SSL (instalación con `s`)

- Certbot instalado vía snap (recomendado para Ubuntu 24.04)
- Certificado Let's Encrypt con renovación automática
- Nginx sirve HTTPS en :443 y redirige HTTP→HTTPS
- Headers de seguridad: HSTS, X-Content-Type-Options, X-Frame-Options, X-XSS-Protection
- TLS 1.2 y 1.3, ciphers modernos

### Sin SSL (instalación con `n`)

- Nginx sirve HTTP en :80
- Para añadir SSL después:

```bash
sudo snap install --classic certbot
sudo certbot --nginx -d tudominio.com --email tu@email.com
```

---

## Firewall

UFW activo con los siguientes puertos:

| Puerto | Servicio | Notas |
|---|---|---|
| 22/tcp | SSH | Siempre abierto |
| 80/tcp | HTTP | Redirige a HTTPS (con SSL) o sirve n8n (sin SSL) |
| 443/tcp | HTTPS | Solo con SSL |

MySQL (:3306) y phpMyAdmin (:8080) solo escuchan en `127.0.0.1`. Para acceder a phpMyAdmin desde tu máquina, usa un túnel SSH:

```bash
ssh -L 8080:127.0.0.1:8080 usuario@servidor
# Luego abre http://localhost:8080 en tu navegador
```

---

## Estructura de Directorios

Después de la instalación, en `~/n8n`:

```
~/n8n/
├── docker-compose.yml     # Configuración de servicios (generado)
├── .env                   # Credenciales (permisos 600)
├── backup.sh              # Script de backup (generado)
├── restore.sh             # Script de restore (generado)
├── n8n-manage.sh          # Script de gestión (generado)
├── backup.log             # Log de backups automáticos
├── README.md              # Documentación local
├── n8n-data/              # Datos de n8n (config, encryption key)
├── postgres-data/         # Datos de PostgreSQL
├── mysql-data/            # Datos de MySQL
├── mysql-init/            # Scripts de inicialización MySQL
└── backups/               # Backups comprimidos + checksums
    ├── n8n_full_20250305_020000.tar.gz
    ├── n8n_full_20250305_020000.sha256
    └── ...
```

---

## Logs

```bash
docker logs n8n -f               # n8n en tiempo real
docker logs n8n-postgres -f      # PostgreSQL
docker logs n8n-mysql -f         # MySQL
docker logs n8n-runner -f        # Task runner
docker logs n8n-phpmyadmin -f    # phpMyAdmin
tail -f ~/n8n/backup.log         # Backups
```

Los logs de Docker tienen rotación automática configurada por contenedor (max 10-20 MB × 3-5 archivos según servicio). El log de backup rota diariamente con 7 días de retención vía logrotate.

---

## Troubleshooting

### n8n no arranca

```bash
cd ~/n8n
docker compose down
docker compose up -d
docker compose logs n8n
```

### PostgreSQL no acepta conexiones

```bash
docker exec n8n-postgres pg_isready -U n8n
docker logs n8n-postgres --tail 50
```

### Credenciales de APIs no funcionan tras migración

Verificar que la encryption key se inyectó correctamente:

```bash
grep N8N_ENCRYPTION_KEY ~/n8n/docker-compose.yml
```

Si no aparece, extraerla del backup:

```bash
./restore.sh --inspect archivo_migrate.tar.gz
# Verificar que muestra "✓ Encryption key"
./restore.sh --credentials archivo_migrate.tar.gz
```

### Memoria insuficiente

```bash
free -h                        # Ver RAM y swap
docker stats --no-stream       # Consumo por contenedor
```

Si hay problemas de OOM, considera reducir servicios o aumentar RAM de la VM.

### Disco lleno

```bash
df -h                          # Espacio en disco
docker system df               # Espacio usado por Docker
docker system prune -a         # Limpiar imágenes/cache no usados
```

---

## Limpieza de Docker

El script `clean.sh` es independiente del instalador. Útil para empezar de cero.

```bash
chmod +x clean.sh
sudo ./clean.sh
```

Proceso interactivo en dos fases: primero lista y elimina contenedores (confirmar con `si`), luego opcionalmente limpia imágenes, volúmenes, redes y cache (confirmar con `LIMPIAR`).

---

## Seguridad

- Credenciales generadas con `openssl rand` (25+ caracteres)
- Contraseñas nunca impresas en terminal, solo en `~/.env` con permisos 600
- MySQL y phpMyAdmin solo accesibles desde localhost
- Firewall UFW activo por defecto
- SSL con TLS 1.2+ y ciphers modernos (si se activa)
- Headers de seguridad en Nginx (HSTS, etc.)
- Red Docker aislada para comunicación entre servicios
- Logs con rotación para evitar llenado de disco
- Swap para prevenir OOM kills (en VM KVM)
- Backup de seguridad automático antes de cada restore

---

## Actualización de n8n

```bash
cd ~/n8n
./n8n-manage.sh backup       # Backup antes de actualizar
./n8n-manage.sh update       # Pull + recrear contenedores
./n8n-manage.sh status       # Verificar
```

---

## Licencia

Scripts de instalación y gestión: uso libre. n8n tiene su propia [licencia](https://github.com/n8n-io/n8n/blob/master/LICENSE.md).
