# FDS Natalia — Infraestructura Docker (producción)

**Autor:** José Manuel Flores Hernández — Flores Dev Studio

Orquestación de producción para los dos proyectos de Pastelería Natalia:
la **API** y la **web**, con **una sola base de datos** compartida entre ambos.

Stack: PHP 8.5-FPM · Nginx · MariaDB 12.3 · Redis 8 — el mismo de
`flores-devstudio-infra`, con el patrón multi-proyecto de
`Docker-Centralized-Multi-Stack-Architecture` (varios proyectos en `projects/`,
un PHP-FPM por proyecto y un Nginx central con un `server{}` por dominio).

## Estructura

```
fds-natalia-infra-docker/
├── docker-compose.yml
├── example.env               ← copiar a .env y configurar
├── .gitignore
├── docker-config/
│   ├── php/
│   │   ├── api/
│   │   │   ├── Dockerfile    ← PHP 8.5 + extensiones Laravel
│   │   │   └── php.ini
│   │   └── web/
│   │       ├── Dockerfile    ← igual + Node 24 para los assets de Vite/Livewire
│   │       └── php.ini
│   ├── nginx/                ← se monta completo como /etc/nginx/conf.d
│   │   ├── 00-default.conf   ← catch-all: Host desconocido → 444
│   │   ├── api.conf          ← server{} de la API
│   │   └── web.conf          ← server{} de la web
│   └── mariadb/
│       └── my.cnf            ← config MariaDB 12.3
├── logs/nginx/               ← logs de Nginx (ignorado en git)
└── projects/             ← aquí se clonan los proyectos (ignorado en git)
    ├── api-pasteleria-natalia/
    └── pasteleria-natalia/
```

Este repo es **solo infraestructura**: `projects/` viaja vacío y cada proyecto se
clona por separado dentro de él.

## Servicios

| Servicio | Contenedor            | Imagen              | Expuesto en el host      |
|----------|-----------------------|---------------------|--------------------------|
| `api`    | `${PHP_API_CONTAINER}`| build docker-config/php/api | no                       |
| `web`    | `${PHP_WEB_CONTAINER}`| build docker-config/php/web | no                       |
| `nginx`  | `${NGINX_CONTAINER}`  | nginx:stable-alpine | `127.0.0.1:${NGINX_PORT}` |
| `db`     | `${MARIADB_CONTAINER}`| mariadb:12.3        | `127.0.0.1:${MARIADB_PORT}` |
| `redis`  | `${REDIS_CONTAINER}`  | redis:8-alpine      | no                       |

## Setup inicial (en el VPS)

```bash
# 1. Clonar la infraestructura
git clone <repo> fds-natalia-infra
cd fds-natalia-infra

# 2. Crear .env
cp example.env .env
nano .env   # cambiar TODOS los passwords

# 3. Clonar los dos proyectos dentro de projects/ (los nombres de carpeta
#    deben ser exactamente estos: los usan nginx y los volúmenes)
git clone <repo-api> projects/api-pasteleria-natalia
git clone <repo-web> projects/pasteleria-natalia

# 4. Poner los dominios reales en docker-config/nginx/api.conf y docker-config/nginx/web.conf

# 5. Levantar
docker compose up -d --build

# 6. Configurar cada proyecto
docker compose exec api composer install --no-dev --optimize-autoloader
docker compose exec api php artisan key:generate
docker compose exec api php artisan migrate --force
docker compose exec api php artisan storage:link

docker compose exec web composer install --no-dev --optimize-autoloader
docker compose exec web php artisan key:generate
docker compose exec web php artisan storage:link
docker compose exec web npm ci && docker compose exec web npm run build
```

## Base de datos compartida — regla de oro

Los dos proyectos apuntan a la **misma** base (`${DB_DATABASE}`). Como ambos son
Laravel, los dos traen migraciones para `users`, `sessions`, `cache`, `jobs` y
`migrations`: si los dos corren `migrate` sobre la misma base, chocan.

**La API es la dueña del esquema.** En concreto:

- Solo `api` corre `php artisan migrate`. La `web` **nunca**.
- Las migraciones que la `web` trae por defecto (users, cache, jobs, sessions)
  se borran de su carpeta `database/migrations` o simplemente no se ejecutan.
- La `web` usa **Redis** para caché, sesiones y colas, así que no necesita esas
  tablas.

Si en algún momento prefieres **dos bases separadas** dentro del mismo MariaDB,
se crea la segunda a mano una sola vez:

```bash
docker compose exec db mariadb -uroot -p -e "
CREATE DATABASE natalia_web CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON natalia_web.* TO 'natalia'@'%';
FLUSH PRIVILEGES;"
```

## `.env` de cada proyecto Laravel

Estos van dentro de `projects/<proyecto>/.env`, no en el `.env` de la orquestación.
Los hosts son los **nombres de servicio** de compose (`db`, `redis`).

**projects/api-pasteleria-natalia/.env**

```dotenv
APP_ENV=production
APP_DEBUG=false
APP_URL=https://api.pasteleria-natalia.com.mx

DB_CONNECTION=mariadb
DB_HOST=db
DB_PORT=3306
DB_DATABASE=natalia
DB_USERNAME=natalia
DB_PASSWORD=<el mismo del .env de la orquestación>

REDIS_CLIENT=phpredis
REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=<el mismo del .env de la orquestación>

CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
CACHE_PREFIX=natalia_api
```

**projects/pasteleria-natalia/.env** — igual, cambiando:

```dotenv
APP_URL=https://pasteleria-natalia.com.mx
CACHE_PREFIX=natalia_web
SESSION_DOMAIN=.pasteleria-natalia.com.mx
```

El `CACHE_PREFIX` distinto es lo que evita que las dos apps se pisen las llaves
en el mismo Redis.

### Confiar en el reverse proxy

Como el TLS lo termina el proxy del host, hay que decirle a Laravel que confíe
en él para que genere URLs `https://`. En `bootstrap/app.php` de **ambos**
proyectos:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(at: '*');
})
```

## Cómo entra el tráfico

Este stack **no escucha a internet**: publica su Nginx solo en
`127.0.0.1:8082`. Quien recibe el 443 es el nginx del host, que vive en el repo
`fds-server-proxy` y reparte por dominio:

```
Cloudflare → :443 nginx del host → 127.0.0.1:8082 → nginx del stack
                                                     ├─ web.conf → php `web`
                                                     └─ api.conf → php `api`
```

Los **dos** dominios de pastelería van al mismo puerto 8082; el nginx interno
los separa otra vez por `Host`. Por eso el `proxy_set_header Host $host;` del
proxy no es opcional: sin él las peticiones caen en el catch-all 444.

El archivo listo está en `fds-server-proxy/sites/pasteleria-natalia.com.mx.conf`.
Cópialo a `/etc/nginx/conf.d/` del servidor **solo cuando ya tengas el dominio
y su Origin Certificate** — si lo copias antes, `nginx -t` falla porque el
certificado no existe.

Los `server_name` de ese archivo y los de `docker-config/nginx/web.conf` y `docker-config/nginx/api.conf`
de este repo deben coincidir exactamente.

## Colas y tareas programadas

No se incluyeron para no levantar contenedores de más. Cuando los necesites,
agrega un servicio que reutilice la misma imagen del proyecto y solo cambie el
comando:

```yaml
  web-queue:
    build: ./docker-config/php/web
    container_name: ${PHP_WEB_CONTAINER}_queue
    restart: unless-stopped
    environment:
      TZ: America/Mexico_City
    command: php artisan queue:work --tries=3 --max-time=3600
    volumes:
      - ./projects/pasteleria-natalia:/var/www/html/pasteleria-natalia
    networks:
      - custom-network
    depends_on:
      redis:
        condition: service_healthy
```

Para el cron de Laravel, lo mismo con `command: php artisan schedule:work`.

## Comandos útiles

```bash
docker compose up -d              # levantar
docker compose down               # bajar
docker compose logs -f nginx      # logs de un servicio
docker compose exec api bash      # entrar al contenedor de la API
docker compose exec web bash      # entrar al contenedor de la web
docker compose ps                 # estado
```

## Publicar cambios (deploy)

```bash
./scripts/deploy.sh web    # o: ./scripts/deploy.sh api
```

Baja el código del proyecto (`git pull`), corre `composer install --no-dev`,
compila los assets si hay `package.json`, `php artisan migrate --force` y
`php artisan optimize`, y **reinicia PHP**. Ese reinicio no es opcional: OPcache
corre con `validate_timestamps=0` y sin él PHP sigue sirviendo el código anterior.
Si alguna vez actualizas a mano, termina siempre con `docker compose restart web` / `api`.

## Respaldos

```bash
./scripts/backup-db.sh
```

Deja `backups/AAAA-MM-DD_HHMM.sql.gz` (ignorado en git) y borra los de más de
14 días (`DIAS=30 ./scripts/backup-db.sh` para cambiarlo). Para que corra solo,
todos los días a las 3:30, con `crontab -e` del usuario que maneja Docker:

```
30 3 * * * /ruta/a/fds-natalia-infra-docker/scripts/backup-db.sh >> /ruta/a/fds-natalia-infra-docker/backups/backup.log 2>&1
```

Un respaldo que solo vive en el mismo servidor no sirve si el servidor se pierde:
copia `backups/` a otro lado (otra máquina, un bucket) con `rsync` o `rclone`.

Restaurar:

```bash
gunzip -c backups/ARCHIVO.sql.gz | docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"'
```

## Logs

- `docker compose logs`: rotan solos (10 MB × 5 por contenedor, `x-logging` del compose).
- `logs/nginx/*.log`: los escribe el nginx del stack y hay que rotarlos con el
  logrotate del servidor. Una vez, desde la carpeta del repo:

```bash
sudo tee /etc/logrotate.d/fds-natalia > /dev/null <<EOF
$(pwd)/logs/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

`copytruncate` porque nginx corre dentro del contenedor y no se le puede mandar
la señal para reabrir el archivo.

## Notas de seguridad

- MariaDB y Nginx solo escuchan en `127.0.0.1`; Redis no se publica.
- Redis con `requirepass`.
- PHP-FPM corre como `www-data` (no-root), con `php.ini-production`,
  `expose_php=Off` y `display_errors=Off`.
- OPcache con `validate_timestamps=0`: `scripts/deploy.sh` reinicia PHP al final
  de cada publicación (ver *Publicar cambios*).
- Logs de Docker con tope de tamaño y respaldos diarios de la base (ver arriba).
- Un `Host` que no coincida con ningún dominio configurado recibe 444.
