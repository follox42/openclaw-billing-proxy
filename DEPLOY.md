# Deploy claude-bypass on Coolify (reseau Docker interne)

Setup specifique : Coolify + Docker network interne, **pas** d'exposition tailnet/public. Claude CLI installe **dans le container** (pas sur l'host), credentials persistes via volume Docker.

## Architecture

```
[OpenClaw container]
       |
       | http://claude-bypass:18801
       v
[claude-bypass container]
       |
       +-- claude CLI installe DANS le container
       +-- /root/.claude/ persiste via volume "claude-creds"
       +-- proxy.js fetch api.anthropic.com avec OAuth token
              |
              v
        api.anthropic.com (sub Pro/Max via injection fingerprint)
```

Tout en interne Docker. Pas de port expose host. Pas de domaine public.

## Etape 1 — Deploy via Coolify UI

1. **Coolify -> New Resource -> Docker Compose**
2. **Source** : Git repository
   - URL : `https://github.com/follox42/openclaw-billing-proxy`
   - Branch : `master`
   - Build pack : Docker Compose
3. **Project** : meme project que ton OpenClaw (pour partager le reseau Docker)
4. **Domain** : aucun (pas d'expose public/tailnet)
5. **Persistent storage** : volume `claude-creds` deja declare — Coolify le gere auto
6. **Deploy**

Build ~30s (npm install claude CLI). Le container demarre. Le proxy log no credentials — normal, on va login juste apres.

## Etape 2 — Login Claude depuis l'interieur du container

Via Coolify UI (Resources -> claude-bypass -> Terminal) ou SSH sur l'host :

```bash
docker exec -it claude-bypass claude auth login
```

Sortie :
```
Open this URL in your browser:
https://claude.ai/oauth/authorize?code=true&...

After authorizing, paste the code here.
Code: _
```

Sur ta machine locale :
1. Open URL en browser
2. Login Claude.ai (compte Pro/Max)
3. Anthropic affiche `XXXX#YYYY`
4. Copy l'integralite, paste dans le terminal du container, Enter

Le fichier `/root/.claude/.credentials.json` est dans le volume `claude-creds` -> persiste au redemarrage.

## Etape 3 — Verifier l'auth

```bash
docker exec claude-bypass claude auth status
# loggedIn: true, subscriptionType: max (ou pro)
```

## Etape 4 — Cron de refresh

Le token expire ~24h. Le binaire `claude` auto-refresh quand invoque.

### Option A — Coolify Scheduled Task (recommande)

Coolify UI -> claude-bypass -> Scheduled Tasks :
```
Command: claude -p "ping" --max-turns 1 --no-session-persistence
Schedule: 0 6 * * *
```

### Option B — Cron host

```bash
0 6 * * * docker exec claude-bypass claude -p "ping" --max-turns 1 --no-session-persistence > /dev/null 2>&1
```

## Etape 5 — Verifier le proxy

```bash
docker exec claude-bypass curl -s http://localhost:18801/health
# {"status":"healthy","version":"2.2.3","subscriptionType":"max","tokenValid":true,...}
```

Test reel :
```bash
docker exec claude-bypass curl -s -X POST http://localhost:18801/v1/messages \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-6-20250929","max_tokens":50,"messages":[{"role":"user","content":"Reply OK"}]}'
```

Verifier sur `console.anthropic.com/usage` que c'est compte comme **Claude Code subscription**, pas Extra Usage.

## Etape 6 — Configurer OpenClaw

Dans `~/.openclaw/openclaw.json` :

```json
{
  "models": {
    "providers": {
      "anthropic": {
        "baseUrl": "http://claude-bypass:18801"
      }
    }
  }
}
```

**Critique** :
- `baseUrl` est le SEUL mecanisme qui route OpenClaw via le proxy (env vars marchent pas)
- Supprimer toute API key Anthropic dans `~/.openclaw/agents/*/agent/auth-profiles.json` (sinon OpenClaw bypass)
- Verifier que OpenClaw et claude-bypass sont sur le **meme reseau Docker** (meme Coolify project)
- Restart : `openclaw gateway restart`
- Verifier : `openclaw models status` -> `base: http://claude-bypass:18801`

## Etape 7 — (Optionnel) Acces depuis machine dev

Via SSH tunnel sur demande :
```bash
ssh -L 18801:claude-bypass:18801 user@coolify-host
```
Cursor/Cline pointent sur `http://localhost:18801`.

## Backup credentials

```bash
# Sauvegarder
docker exec claude-bypass cat /root/.claude/.credentials.json > ~/backups/claude-creds.json
chmod 600 ~/backups/claude-creds.json

# Restaurer
docker exec -i claude-bypass sh -c 'cat > /root/.claude/.credentials.json' < ~/backups/claude-creds.json
```

## Diagnostic

```bash
docker exec claude-bypass node troubleshoot.js
```

Teste 8 layers independamment.

## Update upstream

Hebdomadaire (Anthropic ajuste sa detection) :
```bash
git fetch upstream  # https://github.com/zacdcook/openclaw-billing-proxy
git merge upstream/master
git push origin master
```

Coolify rebuild auto si webhook configure, sinon redeploy via UI. Le volume `claude-creds` est preserve.

## References

- Upstream : https://github.com/zacdcook/openclaw-billing-proxy
- Procedure KB : [[procedures/infra/proc-deploy-claude-bypass-proxy]]
- Contexte 2026 : [[knowledge/ai/anthropic-oauth-2026-state]]
- Projet OpenClaw : [[projects/openclaw/_INDEX]] (etape 23)
