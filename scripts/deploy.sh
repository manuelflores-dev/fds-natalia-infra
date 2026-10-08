#!/usr/bin/env bash
# Publica la versión nueva de un proyecto: baja el código, instala dependencias,
# migra y REINICIA su PHP. El reinicio es obligatorio: OPcache corre con
# validate_timestamps=0 y sin él seguiría sirviendo el código anterior.
#   ./scripts/deploy.sh web
#   ./scripts/deploy.sh api
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    web) SERVICIO=web; PROYECTO=pasteleria-natalia ;;
    api) SERVICIO=api; PROYECTO=api-pasteleria-natalia ;;
    *)   echo "Uso: $0 web|api" >&2; exit 1 ;;
esac

git -C "projects/$PROYECTO" pull --ff-only

run() { docker compose exec -T -e COMPOSER_HOME=/tmp/composer -e npm_config_cache=/tmp/npm "$SERVICIO" "$@"; }

run composer install --no-dev --optimize-autoloader --no-interaction
# Solo la imagen de la web trae Node para compilar los assets.
if [ "$SERVICIO" = web ] && [ -f "projects/$PROYECTO/package.json" ]; then
    run sh -c 'npm ci && npm run build'
fi
run php artisan migrate --force
run php artisan optimize

docker compose restart "$SERVICIO"
echo "OK: $PROYECTO publicado y $SERVICIO reiniciado."
