cd /home/dlesieur/Documents/ft_transcendence
# Retrieve Vault root token via fly ssh console; keep it ONLY in a shell var (never echoed).
TOKEN=$(docker run --rm -e HOME=/fly-home -v vaultfly_home:/fly-home flyio/flyctl:latest \
  ssh console --app track-binocle-vault --command 'jq -r .root_token /vault/data/.vault-keys.json' 2>/dev/null \
  | grep -oE 'hvs\.[A-Za-z0-9_-]+|s\.[A-Za-z0-9]+' | head -1)
if [ -z "$TOKEN" ]; then echo "FAILED to retrieve root token; raw output:"; docker run --rm -e HOME=/fly-home -v vaultfly_home:/fly-home flyio/flyctl:latest ssh console --app track-binocle-vault --command 'jq -r .root_token /vault/data/.vault-keys.json' 2>&1 | head -8; exit 1; fi
echo "root token retrieved: prefix=${TOKEN%%"${TOKEN#????}"}*** length=${#TOKEN}"
echo "=== read-only status against Fly Vault with retrieved token ==="
VAULT_API_KEY="$TOKEN" VAULT_ADDR=https://track-binocle-vault.fly.dev make vault-status-shared 2>&1 | tail -40