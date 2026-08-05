#!/usr/bin/env bash
#
# install-jikan.sh
#
# Self-hosted Jikan (MyAnimeList API) stack installer, wired for use as the
# JIKAN_API_BASE backend for aiometadata (https://github.com/cedya77/aiometadata).
#
# Run this from an empty directory you create yourself, e.g.:
#   mkdir jikan && cd jikan && curl -O .../install-jikan.sh && bash install-jikan.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || { echo "docker is not installed or not on PATH."; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "docker compose (v2 plugin) is required."; exit 1; }

if [ -f compose.yaml ] || [ -f docker-compose.yaml ]; then
  echo "A compose file already exists in this directory."
  read -rp "Continue and overwrite generated files (secrets are preserved)? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# ---------------------------------------------------------------------------
# 1. Ask which Docker network aiometadata is reachable on
# ---------------------------------------------------------------------------
echo
echo "Jikan needs to share a Docker network with your aiometadata container so"
echo "it can be reached at http://jikan_rest:8080/v4"
echo
read -rp "What Docker network would you like to add Jikan to? " NET_NAME

if [ -z "$NET_NAME" ]; then
  echo "A network name is required."
  exit 1
fi

if docker network inspect "$NET_NAME" >/dev/null 2>&1; then
  echo "Found existing network '$NET_NAME' — will attach Jikan to it."
else
  echo "Network '$NET_NAME' does not exist yet."
  read -rp "Create it now? [Y/n] " create_ans
  if [[ ! "$create_ans" =~ ^[Nn]$ ]]; then
    docker network create "$NET_NAME"
    echo "Created network '$NET_NAME'."
    echo "NOTE: make sure your aiometadata compose stack also joins this network"
    echo "      (add it under a top-level 'networks:' + service 'networks:' entry),"
    echo "      or Jikan won't be reachable from it."
  else
    echo "Aborting — network must exist first."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 2. Generate secrets (idempotent — won't clobber existing ones on rerun)
# ---------------------------------------------------------------------------
mkdir -p secrets
gen_secret() {
  local file="$1" value="$2"
  if [ ! -f "secrets/$file" ]; then
    printf '%s' "$value" > "secrets/$file"
    echo "generated secrets/$file"
  fi
}

gen_secret "db_username.txt" "jikan"
gen_secret "db_admin_username.txt" "jikanadmin"
[ -f secrets/db_password.txt ]       || openssl rand -hex 24 | tr -d '\n' > secrets/db_password.txt
[ -f secrets/db_admin_password.txt ] || openssl rand -hex 24 | tr -d '\n' > secrets/db_admin_password.txt
[ -f secrets/redis_password.txt ]    || openssl rand -hex 24 | tr -d '\n' > secrets/redis_password.txt
[ -f secrets/typesense_api_key.txt ] || openssl rand -hex 24 | tr -d '\n' > secrets/typesense_api_key.txt
chmod 644 secrets/*.txt

# ---------------------------------------------------------------------------
# 3. Write RepositoryQuery.php (RoadRunner memoised-builder patch)
# ---------------------------------------------------------------------------
cat > RepositoryQuery.php << 'EOF'
<?php

namespace App\Support;

use App\Contracts\RepositoryQuery as RepositoryQueryContract;
use Illuminate\Contracts\Database\Query\Builder;
use Illuminate\Support\Collection;
use Laravel\Scout\Builder as ScoutBuilder;

class RepositoryQuery extends RepositoryQueryBase implements RepositoryQueryContract
{
    public function filter(Collection $params): Builder|ScoutBuilder
    {
        // queryable() memoises the builder. Repositories are singletons that outlive
        // a request under RoadRunner, so the memoised instance accumulates every
        // previous request's where clauses (genre A AND genre B AND ... => 0 results).
        // Always start from a fresh builder.
        return $this->queryable(true)->filter($params);
    }

    public function search(string $keywords, ?\Closure $callback = null): ScoutBuilder
    {
        return $this->searchable($keywords, $callback, true);
    }

    public function where(string $key, mixed $value): Builder
    {
        return $this->queryable(true)->where($key, $value);
    }
}
EOF

# ---------------------------------------------------------------------------
# 4. Write Dockerfile (bakes the patch into the image — no bind mount needed)
# ---------------------------------------------------------------------------
cat > Dockerfile << 'EOF'
FROM docker.io/jikanme/jikan-rest:latest

COPY RepositoryQuery.php /app/app/Support/RepositoryQuery.php
EOF

# ---------------------------------------------------------------------------
# 5. Write mongo-init.js (creates app user + indexes on first boot)
# ---------------------------------------------------------------------------
cat > mongo-init.js << 'EOF'
const userToCreate = fs.readFileSync('/run/secrets/jikan_db_username', 'utf8').trim();
const userPassword = fs.readFileSync('/run/secrets/jikan_db_password', 'utf8').trim();
db = db.getSiblingDB("admin");
db.createUser({ user: userToCreate, pwd: userPassword, roles: [{ role: "readWrite", db: "jikan" }] });
db = db.getSiblingDB("jikan");
db.createUser({ user: userToCreate, pwd: userPassword, roles: [{ role: "readWrite", db: "jikan" }] });

// Mirrors database/migrations/2022_12_04_210448_squash.php.
const fields = [
  "aired", "airing", "episodes", "members", "favorites", "popularity", "rank",
  "rating", "score", "scored_by", "status", "type", "source",
  "title", "title_english", "title_japanese", "title_synonyms",
  "demographics.mal_id", "explicit_genres.mal_id", "genres.mal_id",
  "licensors.mal_id", "producers.mal_id", "studios.mal_id", "themes.mal_id",
  "aired.from", "aired.to",
];
fields.forEach(f => db.anime.createIndex({ [f]: 1 }, { name: f }));
db.anime.createIndex({ mal_id: 1 }, { name: "mal_id", unique: true });
db.anime.createIndex(
  { title: "text", title_japanese: "text" },
  { name: "search", weights: { title: 50, title_japanese: 5 } }
);
print("anime indexes created: " + db.anime.getIndexes().length);
EOF

# ---------------------------------------------------------------------------
# 6. Write jikan-indexes.js / jikan-dedupe.js (manual-repair helpers, kept
#    around in case the mongo data dir was ever non-empty on first boot)
# ---------------------------------------------------------------------------
cat > jikan-indexes.js << 'EOF'
// Mirrors database/migrations/2022_12_04_210448_squash.php. Safe to re-run.
const d = db.getSiblingDB("jikan");
const fields = [
  "aired", "airing", "episodes", "members", "favorites", "popularity", "rank",
  "rating", "score", "scored_by", "status", "type", "source",
  "title", "title_english", "title_japanese", "title_synonyms",
  "demographics.mal_id", "explicit_genres.mal_id", "genres.mal_id",
  "licensors.mal_id", "producers.mal_id", "studios.mal_id", "themes.mal_id",
  "aired.from", "aired.to",
];
fields.forEach(f => d.anime.createIndex({ [f]: 1 }, { name: f }));
try {
  d.anime.createIndex({ mal_id: 1 }, { name: "mal_id", unique: true });
} catch (e) {
  print("mal_id index failed, run jikan-dedupe.js first: " + e.codeName);
}
d.anime.createIndex(
  { title: "text", title_japanese: "text" },
  { name: "search", weights: { title: 50, title_japanese: 5 } }
);
print("anime indexes: " + d.anime.getIndexes().length);
EOF

cat > jikan-dedupe.js << 'EOF'
const d = db.getSiblingDB("jikan");
d.anime.aggregate([
  { $group: { _id: "$mal_id", ids: { $push: "$_id" }, n: { $sum: 1 } } },
  { $match: { n: { $gt: 1 } } }
], { allowDiskUse: true }).forEach(g => {
  g.ids.slice(1).forEach(id => d.anime.deleteOne({ _id: id }));
  print("mal_id " + g._id + ": removed " + (g.n - 1));
});
d.anime.createIndex({ mal_id: 1 }, { name: "mal_id", unique: true });
print("anime indexes: " + d.anime.getIndexes().length);
EOF

# ---------------------------------------------------------------------------
# 7. Write .env.compose
# ---------------------------------------------------------------------------
cat > .env.compose << 'EOF'
APP_DEBUG=false
LOG_LEVEL=info
APP_ENV=production
# Indexers self-call the API; must point at RoadRunner's port (8080), NOT the default port 80
APP_URL=http://127.0.0.1:8080
CACHING=true
CACHE_DRIVER=redis
REDIS_HOST=jikan_redis
REDIS_PASSWORD__FILE=/run/secrets/jikan_redis_password
DB_CONNECTION=mongodb
DB_HOST=jikan_mongo
DB_DATABASE=jikan
DB_USERNAME__FILE=/run/secrets/jikan_db_username
DB_ADMIN__FILE=/run/secrets/jikan_db_username
DB_PASSWORD__FILE=/run/secrets/jikan_db_password
SCOUT_DRIVER=typesense
SCOUT_QUEUE=false
TYPESENSE_HOST=jikan_typesense
TYPESENSE_PORT=8108
TYPESENSE_API_KEY__FILE=/run/secrets/jikan_typesense_api_key
CORS_MIDDLEWARE=true
MICROCACHING=true
MICROCACHING_EXPIRE=60
MAX_RESULTS_PER_PAGE=50
EOF

# ---------------------------------------------------------------------------
# 8. Write compose.yaml — jikan_rest joins BOTH the internal network (to talk
#    to its own mongo/redis/typesense) and the external shared network (so
#    aiometadata can reach it by container name).
# ---------------------------------------------------------------------------
export JIKAN_NET="$NET_NAME"
cat > compose.yaml << EOF
secrets:
  jikan_db_username:       { file: ./secrets/db_username.txt }
  jikan_db_password:       { file: ./secrets/db_password.txt }
  jikan_db_admin_username: { file: ./secrets/db_admin_username.txt }
  jikan_db_admin_password: { file: ./secrets/db_admin_password.txt }
  jikan_redis_password:    { file: ./secrets/redis_password.txt }
  jikan_typesense_api_key: { file: ./secrets/typesense_api_key.txt }

networks:
  jikan_internal:
    driver: bridge
  shared:
    external: true
    name: ${JIKAN_NET}

services:
  jikan_rest:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: jikan_rest
    hostname: jikan-rest-api
    user: "10001:10001"
    restart: unless-stopped
    env_file: [ .env.compose ]
    secrets: [ jikan_db_username, jikan_db_password, jikan_redis_password, jikan_typesense_api_key ]
    networks: [ jikan_internal, shared ]
    expose: [ 8080 ]
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q 'http://127.0.0.1:2114/health?plugin=http'"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    depends_on:
      jikan_mongo:     { condition: service_healthy }
      jikan_redis:     { condition: service_healthy }
      jikan_typesense: { condition: service_started }

  jikan_mongo:
    image: docker.io/mongo:focal
    container_name: jikan_mongo
    hostname: jikan_mongo
    restart: unless-stopped
    command: "--wiredTigerCacheSizeGB 0.5"
    secrets: [ jikan_db_username, jikan_db_password, jikan_db_admin_username, jikan_db_admin_password ]
    networks: [ jikan_internal ]
    environment:
      MONGO_INITDB_ROOT_USERNAME_FILE: /run/secrets/jikan_db_admin_username
      MONGO_INITDB_ROOT_PASSWORD_FILE: /run/secrets/jikan_db_admin_password
      MONGO_INITDB_DATABASE: jikan_admin
    volumes:
      - ./data/mongo:/data/db
      - ./mongo-init.js:/docker-entrypoint-initdb.d/mongo-init.js:ro
    healthcheck:
      test: ["CMD-SHELL", "mongosh mongodb://localhost:27017 --quiet --eval 'db.runCommand(\"ping\").ok'"]
      interval: 30s
      timeout: 10s
      retries: 5

  jikan_redis:
    image: docker.io/redis:6-alpine
    container_name: jikan_redis
    hostname: jikan_redis
    restart: unless-stopped
    secrets: [ jikan_redis_password ]
    networks: [ jikan_internal ]
    command: ["/bin/sh", "-c", "redis-server --requirepass \"\$\$(cat /run/secrets/jikan_redis_password)\" --appendonly yes"]
    volumes:
      - ./data/redis:/data
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"\$\$(cat /run/secrets/jikan_redis_password)\" ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 5

  jikan_typesense:
    image: docker.io/typesense/typesense:0.24.1
    container_name: jikan_typesense
    hostname: jikan_typesense
    restart: unless-stopped
    entrypoint: /bin/sh
    secrets: [ jikan_typesense_api_key ]
    networks: [ jikan_internal ]
    command: ["-c", "TYPESENSE_API_KEY=\"\$\$(cat /run/secrets/jikan_typesense_api_key)\" /opt/typesense-server --data-dir /data"]
    volumes:
      - ./data/typesense:/data
EOF

mkdir -p data/mongo data/redis data/typesense

# ---------------------------------------------------------------------------
# 9. Build and start
# ---------------------------------------------------------------------------
echo
echo "Building and starting the Jikan stack..."
docker compose build jikan_rest
docker compose up -d

echo
echo "Waiting for jikan_rest to become healthy..."
for i in $(seq 1 30); do
  status="$(docker inspect -f '{{.State.Health.Status}}' jikan_rest 2>/dev/null || echo starting)"
  [ "$status" = "healthy" ] && break
  sleep 5
done

if [ "$status" != "healthy" ]; then
  echo "jikan_rest did not report healthy yet — check 'docker compose logs jikan_rest'."
else
  echo "jikan_rest is healthy."
fi

# ---------------------------------------------------------------------------
# 10. Seed fast metadata (genres, producers, current season/schedule)
# ---------------------------------------------------------------------------
echo
echo "Seeding fast metadata (genres, producers, current season, schedule)..."
docker exec jikan_rest php artisan indexer:genres || true
docker exec jikan_rest php artisan indexer:producers || true
docker exec jikan_rest php artisan indexer:anime-current-season || true
docker exec jikan_rest php artisan indexer:anime-schedule || true

echo
echo "============================================================"
echo " Jikan is up on network '$NET_NAME' as container 'jikan_rest'."
echo
echo " Add this to aiometadata's .env:"
echo "   JIKAN_API_BASE=http://jikan_rest:8080/v4"
echo
echo " aiometadata's compose service must also join the '$NET_NAME'"
echo " network for that hostname to resolve."
echo
echo " Full catalog (~30k anime, several hours) is NOT run automatically."
echo " Kick it off whenever you're ready with:"
echo "   docker exec -d jikan_rest sh -c 'php artisan indexer:anime --delay=1 >> /tmp/indexer-anime.log 2>&1'"
echo " Track it with:"
echo "   docker exec jikan_rest tail -f /tmp/indexer-anime.log"
echo "============================================================"
