#!/bin/bash

# Script de limpieza completa de Docker para Ubuntu 24.04
# Autor: Claude
# Descripción: Lista contenedores, permite eliminarlos y limpia Docker completamente

# Colores para salida
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

# Función para imprimir encabezados
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

# Verificar si Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker no está instalado en este sistema${NC}"
    exit 1
fi

# Verificar si el usuario tiene permisos de Docker
if ! docker ps &> /dev/null; then
    echo -e "${RED}Error: No tienes permisos para ejecutar Docker${NC}"
    echo -e "${YELLOW}Intenta ejecutar: sudo ./docker_cleanup.sh${NC}"
    exit 1
fi

print_header "CONTENEDORES DOCKER EN EJECUCIÓN"

# Listar contenedores en ejecución
RUNNING_CONTAINERS=$(docker ps -q)

if [ -z "$RUNNING_CONTAINERS" ]; then
    echo -e "${GREEN}No hay contenedores en ejecución${NC}"
else
    docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}"
    echo -e "\n${YELLOW}Total de contenedores en ejecución: $(echo "$RUNNING_CONTAINERS" | wc -l)${NC}"
fi

# Listar TODOS los contenedores (incluyendo detenidos)
print_header "TODOS LOS CONTENEDORES (Incluyendo detenidos)"
ALL_CONTAINERS=$(docker ps -a -q)

if [ -z "$ALL_CONTAINERS" ]; then
    echo -e "${GREEN}No hay contenedores en el sistema${NC}"
else
    docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}"
    echo -e "\n${YELLOW}Total de contenedores: $(echo "$ALL_CONTAINERS" | wc -l)${NC}"
fi

# Preguntar si desea eliminar los contenedores
echo -e "\n${YELLOW}¿Deseas detener y eliminar todos los contenedores?${NC}"
read -p "Escribe 'si' para confirmar: " CONFIRM

if [ "$CONFIRM" != "si" ]; then
    echo -e "${RED}Operación cancelada${NC}"
    exit 0
fi

# Detener todos los contenedores en ejecución
if [ ! -z "$RUNNING_CONTAINERS" ]; then
    print_header "DETENIENDO CONTENEDORES"
    docker stop $(docker ps -q)
    echo -e "${GREEN}✓ Contenedores detenidos${NC}"
fi

# Eliminar todos los contenedores
if [ ! -z "$ALL_CONTAINERS" ]; then
    print_header "ELIMINANDO CONTENEDORES"
    docker rm $(docker ps -a -q)
    echo -e "${GREEN}✓ Contenedores eliminados${NC}"
fi

# Preguntar si desea hacer limpieza completa
echo -e "\n${RED}¿Deseas hacer una LIMPIEZA COMPLETA de Docker?${NC}"
echo -e "${YELLOW}Esto eliminará:${NC}"
echo "  - Todas las imágenes"
echo "  - Todos los volúmenes"
echo "  - Todas las redes personalizadas"
echo "  - Todo el cache de construcción"
echo -e "\n${RED}Docker quedará como recién instalado${NC}"
read -p "Escribe 'LIMPIAR' para confirmar: " DEEP_CLEAN

if [ "$DEEP_CLEAN" != "LIMPIAR" ]; then
    echo -e "${YELLOW}Limpieza completa cancelada. Los contenedores fueron eliminados.${NC}"
    exit 0
fi

# Limpieza completa
print_header "LIMPIEZA COMPLETA DE DOCKER"

echo -e "${YELLOW}Eliminando imágenes...${NC}"
docker rmi $(docker images -q) -f 2>/dev/null
echo -e "${GREEN}✓ Imágenes eliminadas${NC}"

echo -e "\n${YELLOW}Eliminando volúmenes...${NC}"
docker volume rm $(docker volume ls -q) 2>/dev/null
echo -e "${GREEN}✓ Volúmenes eliminados${NC}"

echo -e "\n${YELLOW}Eliminando redes personalizadas...${NC}"
docker network rm $(docker network ls -q) 2>/dev/null
echo -e "${GREEN}✓ Redes eliminadas${NC}"

echo -e "\n${YELLOW}Limpiando sistema completo (prune)...${NC}"
docker system prune -a --volumes -f
echo -e "${GREEN}✓ Sistema limpiado${NC}"

# Mostrar estado final
print_header "ESTADO FINAL DEL SISTEMA"

echo -e "${BLUE}Contenedores:${NC} $(docker ps -a | wc -l | awk '{print $1-1}')"
echo -e "${BLUE}Imágenes:${NC} $(docker images | wc -l | awk '{print $1-1}')"
echo -e "${BLUE}Volúmenes:${NC} $(docker volume ls | wc -l | awk '{print $1-1}')"
echo -e "${BLUE}Redes:${NC} $(docker network ls | wc -l | awk '{print $1-1}')"

echo -e "\n${GREEN}Espacio recuperado:${NC}"
docker system df

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✓ LIMPIEZA COMPLETADA EXITOSAMENTE${NC}"
echo -e "${GREEN}========================================${NC}\n"