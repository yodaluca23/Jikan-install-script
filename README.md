# Jikan-install-script
This is a lazy jikan install script for your own selfhosted aiometadata instance. This script is entirely AI generated, please use it with caution!

## Deploying

1. Create an empty directory for the stack and `cd` into it:

```bash
   mkdir jikan && cd jikan
```

2. Download the install script:

```bash
   curl -fsSL https://raw.githubusercontent.com/Redhair777/Jikan-install-script/main/install-jikan.sh -o install-jikan.sh
   chmod +x install-jikan.sh
```

   > Don't pipe this directly into `bash` (`curl ... | bash`) — the script prompts you interactively, and piping breaks that prompt since the script consumes stdin itself. Download it first, then run the local file.

3. Run it:

```bash
   ./install-jikan.sh
```

4. When prompted, enter the name of the **Docker network your aiometadata container is already on** (create that network first if it doesn't exist yet — the script can create it for you too, but aiometadata's own compose file still needs to join it).

5. The script will:
   - Generate secrets, the Dockerfile (with the RoadRunner query-builder patch baked in), Mongo init script, and `compose.yaml`
   - Build the custom Jikan image
   - Start Mongo, Redis, Typesense, and `jikan_rest`
   - Wait for `jikan_rest` to report healthy
   - Kick off initial metadata seeding (genres, producers, current season, schedule) in the background

6. Add this to aiometadata's `.env` or via dashboard:

```env
   JIKAN_API_BASE=http://jikan_rest:8080/v4
```

   Then restart the aiometadata container so it picks up the new variable.

### Seeding the full catalog

The full anime catalog (~30k entries) takes several hours and is **not** started automatically. Kick it off manually once you're ready:

```bash
docker exec -d jikan_rest sh -c 'php artisan indexer:anime --delay=1 >> /tmp/indexer-anime.log 2>&1'
```

Track progress:

```bash
docker exec jikan_rest tail -f /tmp/indexer-anime.log
```

Until this finishes, direct lookups (e.g. `/v4/anime/1`) work immediately, but search, seasons, `top`, and genre catalogs will be empty or incomplete.

### Re-running the script

Safe to run again at any time (e.g. after pulling an update) — it won't regenerate secrets or touch existing data volumes, only refreshes config files and re-runs `docker compose up -d`.
