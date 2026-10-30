#!/usr/bin/env bash
# =============================================================================
#  setup-claude-dev-lxc.sh
#  À lancer EN ROOT sur l'hôte Proxmox (Shell du nœud).
#  Crée un conteneur LXC Debian (13 par défaut) pour du dev Java / Spring / Mongo / Docker,
#  avec git, GitHub CLI et Claude Code démarré automatiquement en Remote Control.
#
#  Lancement interactif (assistant) :   ./setup-claude-dev-lxc.sh
#  Lancement sans assistant :           NO_WIZARD=1 GH_TOKEN=... ./setup-claude-dev-lxc.sh
#  Toute variable ci-dessous peut être passée en environnement ; elle devient
#  alors la valeur proposée par défaut dans l'assistant.
# =============================================================================
# Relance automatiquement avec bash si le script a été lancé avec « sh »
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

# ----------------------------- PARAMÈTRES ------------------------------------
CTID="${CTID:-}"                          # vide = prochain ID libre
HOSTNAME_CT="${HOSTNAME_CT:-claude-dev}"
DEBIAN_VERSION="${DEBIAN_VERSION:-13}"    # 12 (bookworm) | 13 (trixie)
STORAGE="${STORAGE:-}"                    # vide = choix / premier stockage compatible
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"
DISK_GB="${DISK_GB:-64}"
CORES="${CORES:-4}"
RAM_MB="${RAM_MB:-8192}"
SWAP_MB="${SWAP_MB:-2048}"
BRIDGE="${BRIDGE:-vmbr0}"
IP_CONF="${IP_CONF:-dhcp}"                # ex: "192.168.1.50/24,gw=192.168.1.1"
DEV_USER="${DEV_USER:-dev}"
JAVA_VERSION="${JAVA_VERSION:-25}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:8}"
MONGO_ROOT_USER="${MONGO_ROOT_USER:-admin}"
MONGO_ROOT_PWD="${MONGO_ROOT_PWD:-$(openssl rand -hex 12)}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-/root/.ssh/authorized_keys}"

# Git / GitHub
GIT_NAME="${GIT_NAME:-Claude Bot}"
GIT_EMAIL="${GIT_EMAIL:-claude-bot@example.com}"
GIT_DEFAULT_BRANCH="${GIT_DEFAULT_BRANCH:-main}"
GH_TOKEN="${GH_TOKEN:-}"                  # token fine-grained (recommandé)
GH_REPO="${GH_REPO:-}"                    # "org/repo" à cloner (optionnel)
GEN_SSH_KEY="${GEN_SSH_KEY:-auto}"        # auto = seulement s'il n'y a pas de token

# Jira Cloud (optionnel) — exporté dans ~/.dev-env pour l'API REST
JIRA_URL="${JIRA_URL:-}"                  # ex: https://mon-org.atlassian.net
JIRA_EMAIL="${JIRA_EMAIL:-}"              # compte Atlassian propriétaire du token
JIRA_API_TOKEN="${JIRA_API_TOKEN:-}"      # https://id.atlassian.com/manage-profile/security/api-tokens
JIRA_PROJECT="${JIRA_PROJECT:-}"          # clé du projet par défaut (optionnel)

# Claude Code Remote Control
RC_ENABLE="${RC_ENABLE:-1}"
RC_NAME="${RC_NAME:-}"                    # vide = nom d'hôte
RC_DIR="${RC_DIR:-}"                      # relatif au home ; vide = workspace ou le repo cloné
RC_SPAWN="${RC_SPAWN:-same-dir}"          # same-dir | worktree | session
RC_PERMISSION_MODE="${RC_PERMISSION_MODE:-default}"
# -----------------------------------------------------------------------------

BT="Claude Code — conteneur de dev"
log() { echo -e "\e[1;32m[+]\e[0m $*"; }
die() { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }
valid_hostname() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }

command -v pct >/dev/null || die "pct introuvable : ce script doit tourner sur l'hôte Proxmox."

# =============================== ASSISTANT ===================================
w_input()  { whiptail --backtitle "$BT" --title "$1" --inputbox "$2" 12 72 "$3" 3>&1 1>&2 2>&3 || die "Annulé."; }
w_pass()   { whiptail --backtitle "$BT" --title "$1" --passwordbox "$2" 12 72 3>&1 1>&2 2>&3 || die "Annulé."; }
w_yesno()  { whiptail --backtitle "$BT" --title "$1" --yesno "$2" 12 72; }
w_menu()   { local t="$1" m="$2" d="$3"; shift 3
             whiptail --backtitle "$BT" --title "$t" --default-item "$d" --menu "$m" 18 72 8 "$@" 3>&1 1>&2 2>&3 || die "Annulé."; }

pick_from_list() {  # titre, message, défaut, éléments...
  local t="$1" m="$2" d="$3"; shift 3
  local items=(); for x in "$@"; do items+=("$x" ""); done
  [ "${#items[@]}" -eq 2 ] && { echo "$1"; return; }
  w_menu "$t" "$m" "$d" "${items[@]}"
}

wizard() {
  local MODE
  MODE=$(w_menu "Mode" "Choisis le mode de configuration :" "simple" \
    "simple" "Paramètres essentiels, le reste par défaut" \
    "avance" "Tous les paramètres (ressources, réseau, Java…)")

  # --- Conteneur ---
  while :; do
    HOSTNAME_CT=$(w_input "Nom d'hôte" "Nom du conteneur (lettres, chiffres, tirets — pas de tiret au début ni à la fin) :" "$HOSTNAME_CT")
    valid_hostname "$HOSTNAME_CT" && break
    whiptail --backtitle "$BT" --msgbox "Nom d'hôte invalide : '$HOSTNAME_CT'" 8 60
  done

  if [ "$MODE" = "avance" ]; then
    CTID=$(w_input "ID du conteneur" "ID du conteneur (laisser vide = prochain ID libre) :" "$CTID")
    DEBIAN_VERSION=$(w_menu "Debian" "Version de Debian du conteneur :" "$DEBIAN_VERSION" "13" "trixie (recommandé)" "12" "bookworm")
    CORES=$(w_input "CPU" "Nombre de cœurs :" "$CORES")
    RAM_MB=$(w_input "Mémoire" "RAM en Mo :" "$RAM_MB")
    DISK_GB=$(w_input "Disque" "Taille du disque en Go :" "$DISK_GB")
    mapfile -t _st < <(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}')
    [ "${#_st[@]}" -gt 0 ] && STORAGE=$(pick_from_list "Stockage" "Stockage du disque du conteneur :" "${STORAGE:-${_st[0]}}" "${_st[@]}")
    mapfile -t _br < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)
    [ "${#_br[@]}" -gt 0 ] && BRIDGE=$(pick_from_list "Réseau" "Bridge réseau :" "$BRIDGE" "${_br[@]}")
    IP_CONF=$(w_input "Adresse IP" "« dhcp » ou IP fixe, ex : 192.168.1.50/24,gw=192.168.1.1" "$IP_CONF")
    JAVA_VERSION=$(w_menu "Java" "Version du JDK Temurin :" "$JAVA_VERSION" "17" "LTS" "21" "LTS (recommandé)" "25" "LTS")
  fi

  # --- Git / GitHub ---
  GIT_NAME=$(w_input "Git" "Nom de l'auteur des commits :" "$GIT_NAME")
  GIT_EMAIL=$(w_input "Git" "Email de l'auteur des commits :" "$GIT_EMAIL")

  if [ -z "$GH_TOKEN" ]; then
    GH_TOKEN=$(w_pass "Token GitHub" "Colle ton token GitHub fine-grained (github_pat_…).\nLaisser vide pour le configurer plus tard avec « gh auth login ».\n\n(Ctrl+Shift+V pour coller ; rien ne s'affiche, c'est normal)")
  fi

  if [ -n "$GH_TOKEN" ]; then
    GH_REPO=$(w_input "Dépôt GitHub" "Dépôt à cloner au démarrage, format org/repo\n(vide = aucun) :" "$GH_REPO")
  fi

  if [ "$MODE" = "avance" ]; then
    local ssh_default="--defaultno"; [ -z "$GH_TOKEN" ] && ssh_default=""
    if whiptail --backtitle "$BT" --title "Clé SSH" $ssh_default --yesno \
       "Générer aussi une clé SSH pour GitHub ?\n\nInutile si tu as fourni un token (git passe en HTTPS via gh)." 12 72; then
      GEN_SSH_KEY=1; else GEN_SSH_KEY=0; fi
  fi

  # --- Jira ---
  local jira_default="--defaultno"; [ -n "$JIRA_URL" ] && jira_default=""
  if whiptail --backtitle "$BT" --title "Jira" $jira_default --yesno \
     "Connecter le conteneur à Jira Cloud (API REST par token) ?" 12 72; then
    JIRA_URL=$(w_input "Jira" "URL du site Jira :\n(ex : https://mon-org.atlassian.net)" "$JIRA_URL")
    JIRA_EMAIL=$(w_input "Jira" "Email du compte Atlassian :" "$JIRA_EMAIL")
    if [ -z "$JIRA_API_TOKEN" ]; then
      JIRA_API_TOKEN=$(w_pass "Token Jira" "Colle ton token d'API Atlassian\n(id.atlassian.com → Sécurité → Jetons d'API).\n\n(Ctrl+Shift+V pour coller ; rien ne s'affiche, c'est normal)")
    fi
    JIRA_PROJECT=$(w_input "Jira" "Clé du projet par défaut (optionnel, ex : PROJ) :" "$JIRA_PROJECT")
  else
    JIRA_URL=""; JIRA_EMAIL=""; JIRA_API_TOKEN=""; JIRA_PROJECT=""
  fi

  # --- Remote Control ---
  if w_yesno "Remote Control" "Lancer Claude Code automatiquement en Remote Control au démarrage du conteneur ?"; then
    RC_ENABLE=1
    local def_dir="${RC_DIR:-workspace}"
    [ -z "$RC_DIR" ] && [ -n "$GH_REPO" ] && def_dir="workspace/${GH_REPO##*/}"
    RC_DIR=$(w_input "Dossier de travail" "Dossier où Claude travaille (relatif à /home/${DEV_USER}) :" "$def_dir")
    RC_NAME=$(w_input "Nom de session" "Nom affiché dans claude.ai/code et l'appli :" "${RC_NAME:-$HOSTNAME_CT}")
    RC_SPAWN=$(w_menu "Sessions" "Comment isoler les nouvelles sessions lancées à distance ?" "$RC_SPAWN" \
      "same-dir" "Toutes dans le même dossier" \
      "worktree" "Un worktree git par session (dossier = dépôt git)")
    RC_PERMISSION_MODE=$(w_menu "Permissions" "Mode de permission de Claude :" "$RC_PERMISSION_MODE" \
      "default"     "Demande avant modifications et commandes" \
      "acceptEdits" "Modifie les fichiers seul, demande pour les commandes" \
      "plan"        "Planifie seulement, ne modifie rien")
  else
    RC_ENABLE=0
  fi

  # --- Récapitulatif ---
  local tok="aucun"; [ -n "$GH_TOKEN" ] && tok="fourni"
  local rc="non"; [ "$RC_ENABLE" = 1 ] && rc="oui, ~/${RC_DIR} (${RC_SPAWN}, ${RC_PERMISSION_MODE})"
  local jira="non"; [ -n "$JIRA_URL" ] && jira="${JIRA_URL} (${JIRA_EMAIL}${JIRA_PROJECT:+, projet ${JIRA_PROJECT}})"
  local recap
  recap="Conteneur : ${HOSTNAME_CT}  (ID : ${CTID:-auto}, Debian ${DEBIAN_VERSION})
Ressources : ${CORES} cœurs, ${RAM_MB} Mo RAM, ${DISK_GB} Go sur ${STORAGE:-auto}
Réseau : ${BRIDGE}, ${IP_CONF}
Java : Temurin ${JAVA_VERSION}
Git : ${GIT_NAME} <${GIT_EMAIL}>
Token GitHub : ${tok}    Dépôt : ${GH_REPO:-aucun}
Jira : ${jira}
Remote Control : ${rc}

Lancer la création ?"
  whiptail --backtitle "$BT" --title "Récapitulatif" --yesno "$recap" 18 76 || die "Annulé."
}

if [ "${NO_WIZARD:-0}" != "1" ] && [ -t 0 ] && command -v whiptail >/dev/null; then
  wizard
fi

# ============================== VALIDATIONS ==================================
valid_hostname "$HOSTNAME_CT" || die "Nom d'hôte invalide : '$HOSTNAME_CT'."
if [ -z "$CTID" ]; then
  CTID=$(pvesh get /cluster/nextid) || die "Impossible d'obtenir un ID libre."
elif pct status "$CTID" &>/dev/null || qm status "$CTID" &>/dev/null; then
  die "L'ID $CTID est déjà utilisé par un CT ou une VM."
fi
if [ -z "$STORAGE" ]; then
  STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')
  [ -n "$STORAGE" ] || die "Aucun stockage compatible conteneurs trouvé."
fi
[ "$GEN_SSH_KEY" = "auto" ] && { [ -n "$GH_TOKEN" ] && GEN_SSH_KEY=0 || GEN_SSH_KEY=1; }
[ -z "$RC_NAME" ] && RC_NAME="$HOSTNAME_CT"
if [ -z "$RC_DIR" ]; then
  RC_DIR="workspace"; [ -n "$GH_REPO" ] && RC_DIR="workspace/${GH_REPO##*/}"
fi
RC_DIR="${RC_DIR#/home/${DEV_USER}/}"; RC_DIR="${RC_DIR#\~/}"
JIRA_URL="${JIRA_URL%/}"
if [ -n "${JIRA_URL}${JIRA_EMAIL}${JIRA_API_TOKEN}" ]; then
  [ -n "$JIRA_URL" ] && [ -n "$JIRA_EMAIL" ] && [ -n "$JIRA_API_TOKEN" ] \
    || die "Jira : JIRA_URL, JIRA_EMAIL et JIRA_API_TOKEN doivent être renseignés ensemble."
  [[ "$JIRA_URL" =~ ^https:// ]] || die "Jira : JIRA_URL doit commencer par https:// ('$JIRA_URL')."
fi
log "Conteneur ${HOSTNAME_CT} — ID ${CTID} — stockage ${STORAGE}"

# ============================ 1. TEMPLATE ====================================
log "Recherche du template Debian ${DEBIAN_VERSION}…"
pveam update >/dev/null
TEMPLATE=$(pveam available --section system | awk -v t="debian-${DEBIAN_VERSION}-standard" 'index($2, t) == 1 {print $2}' | sort -V | tail -1)
[ -n "$TEMPLATE" ] || die "Template Debian ${DEBIAN_VERSION} introuvable."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  log "Téléchargement de $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

# ============================ 2. CONTENEUR ===================================
log "Création du CT $CTID ($HOSTNAME_CT)…"
pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME_CT" \
  --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
  --rootfs "${STORAGE}:${DISK_GB}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP_CONF}" \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1 --start 1

log "Attente du réseau…"
NET_OK=0
for _ in {1..30}; do
  # Connexion TCP au miroir apt : teste DNS + accès réel, sans dépendre de ping ni de l'ICMP
  pct exec "$CTID" -- timeout 3 bash -c 'exec 3<>/dev/tcp/deb.debian.org/80' &>/dev/null && { NET_OK=1; break; }
  sleep 2
done
[ "$NET_OK" = 1 ] || die "Pas d'accès à deb.debian.org depuis le CT $CTID (réseau ${BRIDGE}, ${IP_CONF}).
    Vérifier le bridge, la passerelle et le DNS, puis supprimer le CT : pct destroy $CTID --purge"

# ============================ 3. SYSTÈME =====================================
log "Paquets : git, gh, JDK ${JAVA_VERSION}, Maven, Docker…"
pct exec "$CTID" -- bash -s <<EOF
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y full-upgrade
apt-get install -y ca-certificates curl wget gnupg git git-lfs sudo tmux htop unzip zip \
  jq ripgrep build-essential openssh-server openssh-client locales apt-transport-https
sed -i 's/^# *fr_FR.UTF-8/fr_FR.UTF-8/' /etc/locale.gen && locale-gen

install -d -m 0755 /etc/apt/keyrings
ARCH=\$(dpkg --print-architecture)
CODENAME=\$(. /etc/os-release && echo "\$VERSION_CODENAME")   # suit le template choisi

curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb \$CODENAME main" > /etc/apt/sources.list.d/adoptium.list

curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=\$ARCH signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$CODENAME stable" > /etc/apt/sources.list.d/docker.list

curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=\$ARCH signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list

apt-get update
apt-get install -y temurin-${JAVA_VERSION}-jdk maven \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
systemctl enable --now docker ssh

id ${DEV_USER} &>/dev/null || useradd -m -s /bin/bash ${DEV_USER}
usermod -aG sudo,docker ${DEV_USER}
echo "${DEV_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-${DEV_USER}
chmod 440 /etc/sudoers.d/90-${DEV_USER}
install -d -m 700 -o ${DEV_USER} -g ${DEV_USER} /home/${DEV_USER}/.ssh
EOF

if [ -f "$SSH_PUBKEY_FILE" ]; then
  log "Copie des clés SSH d'accès pour ${DEV_USER}"
  pct push "$CTID" "$SSH_PUBKEY_FILE" "/home/${DEV_USER}/.ssh/authorized_keys" \
    --user "$DEV_USER" --group "$DEV_USER" --perms 600
fi

# ============================ 4. GIT / GITHUB ================================
log "Configuration git…"
pct exec "$CTID" -- su - "$DEV_USER" -c "bash -s" <<EOF
set -euo pipefail
git config --global user.name  "${GIT_NAME}"
git config --global user.email "${GIT_EMAIL}"
git config --global init.defaultBranch "${GIT_DEFAULT_BRANCH}"
git config --global pull.rebase true
git config --global fetch.prune true
git config --global push.autoSetupRemote true
git config --global core.autocrlf input
git lfs install --skip-repo
ssh-keyscan -t ed25519,rsa github.com >> ~/.ssh/known_hosts 2>/dev/null
chmod 600 ~/.ssh/known_hosts
if [ "${GEN_SSH_KEY}" = "1" ] && [ ! -f ~/.ssh/id_ed25519 ]; then
  ssh-keygen -t ed25519 -N "" -C "claude@${HOSTNAME_CT}" -f ~/.ssh/id_ed25519 -q
fi
mkdir -p ~/workspace
EOF

GH_AUTH_STATUS="non configurée — lancer « gh auth login » dans le conteneur"
CLONE_STATUS=""
if [ -n "$GH_TOKEN" ]; then
  log "Authentification GitHub CLI…"
  TMP_TOKEN=$(mktemp); chmod 600 "$TMP_TOKEN"; printf '%s' "$GH_TOKEN" > "$TMP_TOKEN"
  pct push "$CTID" "$TMP_TOKEN" "/home/${DEV_USER}/.gh_token" --user "$DEV_USER" --group "$DEV_USER" --perms 600
  shred -u "$TMP_TOKEN" 2>/dev/null || rm -f "$TMP_TOKEN"
  if pct exec "$CTID" -- su - "$DEV_USER" -c \
      'gh auth login --hostname github.com --git-protocol https --with-token < ~/.gh_token && gh auth setup-git; rc=$?; shred -u ~/.gh_token 2>/dev/null || rm -f ~/.gh_token; exit $rc'; then
    GH_AUTH_STATUS="OK (HTTPS via gh)"
    if [ -n "$GH_REPO" ]; then
      log "Clonage de ${GH_REPO}…"
      if pct exec "$CTID" -- su - "$DEV_USER" -c "cd ~/workspace && gh repo clone '${GH_REPO}'"; then
        CLONE_STATUS="cloné dans ~/workspace/${GH_REPO##*/}"
      else
        CLONE_STATUS="ÉCHEC du clonage (droits du token ?)"
      fi
    fi
  else
    GH_AUTH_STATUS="ÉCHEC — vérifier le token puis « gh auth login »"
  fi
fi
pct exec "$CTID" -- su - "$DEV_USER" -c "mkdir -p ~/'${RC_DIR}'"

# ===================== 5. MONGODB, CLAUDE CODE, ENV ==========================
log "MongoDB (Docker), Claude Code, environnement…"
pct exec "$CTID" -- su - "$DEV_USER" -c "bash -s" <<EOF
set -euo pipefail
mkdir -p ~/infra/mongo ~/.claude
cat > ~/infra/mongo/docker-compose.yml <<'YML'
services:
  mongo:
    image: ${MONGO_IMAGE}
    container_name: mongo
    restart: unless-stopped
    ports:
      - "127.0.0.1:27017:27017"
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_ROOT_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PWD}
    volumes:
      - mongo-data:/data/db
volumes:
  mongo-data:
YML
cd ~/infra/mongo && sg docker -c "docker compose up -d"

curl -fsSL https://claude.ai/install.sh | bash

cat > ~/.dev-env <<'RC'
export PATH="\$HOME/.local/bin:\$PATH"
export JAVA_HOME=\$(dirname \$(dirname \$(readlink -f \$(command -v java))))
export SPRING_DATA_MONGODB_URI="mongodb://${MONGO_ROOT_USER}:${MONGO_ROOT_PWD}@localhost:27017/?authSource=admin"
RC
if [ -n "${JIRA_URL}" ]; then
cat >> ~/.dev-env <<'RC'
export JIRA_URL="${JIRA_URL}"
export JIRA_EMAIL="${JIRA_EMAIL}"
export JIRA_API_TOKEN="${JIRA_API_TOKEN}"
export JIRA_PROJECT="${JIRA_PROJECT}"
RC
fi
chmod 600 ~/.dev-env
grep -q 'dev-env' ~/.bashrc || echo '[ -f ~/.dev-env ] && . ~/.dev-env' >> ~/.bashrc

# mongosh : celui de l'image Mongo (même version que le serveur), connecté par défaut
mkdir -p ~/.local/bin
cat > ~/.local/bin/mongosh <<'SH'
#!/usr/bin/env bash
[ -f "\$HOME/.dev-env" ] && . "\$HOME/.dev-env"
case " \$* " in *" mongodb://"*|*" mongodb+srv://"*) ;; *) set -- "\$SPRING_DATA_MONGODB_URI" "\$@" ;; esac
exec docker exec -i\$([ -t 0 ] && [ -t 1 ] && echo t) mongo mongosh "\$@"
SH
chmod 755 ~/.local/bin/mongosh

# Instructions globales pour Claude (valables dans tous les dossiers, jamais committées)
cat > ~/.claude/CLAUDE.md <<'MD'
# Environnement de développement
- OS : Debian ${DEBIAN_VERSION} (LXC Proxmox), utilisateur \`${DEV_USER}\` avec sudo sans mot de passe.
- Java : Temurin ${JAVA_VERSION} — build avec Maven (\`mvn -B verify\`).
- Spring Boot : starters officiels, tests JUnit 5 et Testcontainers.
- MongoDB : conteneur Docker \`mongo\` sur localhost:27017, URI dans \`SPRING_DATA_MONGODB_URI\`.
  \`mongosh\` (wrapper vers le conteneur) s'y connecte par défaut.
- Docker et \`docker compose\` disponibles sans sudo.
- Toujours lancer les tests avant de considérer une tâche terminée.

# Règles git / GitHub
- Ne jamais committer ni pousser directement sur \`${GIT_DEFAULT_BRANCH}\`.
- Une branche par tâche : \`feature/<sujet>\` ou \`fix/<sujet>\`.
- Commits petits et explicites (Conventional Commits : feat:, fix:, refactor:, test:…).
- \`mvn -B verify\` avant chaque push.
- Ouvrir une PR avec \`gh pr create --fill\`, ne jamais la merger soi-même.
- Ne jamais committer de secrets (mots de passe, tokens, fichiers .env).
MD

if [ -n "${JIRA_URL}" ]; then
cat >> ~/.claude/CLAUDE.md <<'MD'

# Jira
- Site : ${JIRA_URL} — projet par défaut : ${JIRA_PROJECT:-aucun}.
- API REST v3 via les variables \`JIRA_URL\`, \`JIRA_EMAIL\`, \`JIRA_API_TOKEN\`, ex. :
  \`curl -sS -u "\$JIRA_EMAIL:\$JIRA_API_TOKEN" "\$JIRA_URL/rest/api/3/issue/CLE-123" | jq\`
- Ne jamais afficher, journaliser ni committer \`JIRA_API_TOKEN\`.
- Lecture libre ; demander confirmation avant de créer, modifier ou commenter un ticket.
MD
fi
EOF

JIRA_STATUS=""
if [ -n "$JIRA_URL" ]; then
  log "Vérification de l'accès Jira…"
  if JIRA_WHO=$(pct exec "$CTID" -- su - "$DEV_USER" -c \
      'set -o pipefail; . ~/.dev-env && curl -fsS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_URL/rest/api/3/myself" | jq -er .displayName'); then
    JIRA_STATUS="OK (${JIRA_WHO})"
  else
    JIRA_STATUS="ÉCHEC — vérifier JIRA_URL, JIRA_EMAIL et le token dans ~/.dev-env"
  fi
fi

# ========================= 6. REMOTE CONTROL =================================
if [ "$RC_ENABLE" = "1" ]; then
  log "Service Claude Remote Control…"
  TMPD=$(mktemp -d)

  cat > "$TMPD/claude-rc.env" <<ENV
RC_NAME="${RC_NAME}"
RC_SPAWN="${RC_SPAWN}"
RC_PERMISSION_MODE="${RC_PERMISSION_MODE}"
RC_DIR="\$HOME/${RC_DIR}"
ENV

  cat > "$TMPD/claude-rc-loop.sh" <<'LOOP'
#!/usr/bin/env bash
[ -f "$HOME/.dev-env" ] && . "$HOME/.dev-env"
. "$HOME/.claude-rc.env"
cd "$RC_DIR" || { echo "Dossier introuvable : $RC_DIR"; sleep 60; exit 1; }
while true; do
  echo "=== $(date '+%F %T') — démarrage de claude remote-control (${RC_NAME}) ==="
  claude remote-control --name "$RC_NAME" --spawn "$RC_SPAWN" --permission-mode "$RC_PERMISSION_MODE" || true
  echo "=== claude s'est arrêté. Nouvel essai dans 30 s ==="
  echo "    Pas encore connecté ? Ctrl+B puis C, lance « claude », fais /login puis /exit."
  echo "    Pour sortir de tmux sans rien arrêter : Ctrl+B puis D."
  sleep 30
done
LOOP

  cat > "$TMPD/claude-rc.service" <<UNIT
[Unit]
Description=Claude Code Remote Control (${RC_NAME})
Wants=network-online.target
After=network-online.target docker.service

[Service]
# Superviseur : recrée la session tmux si elle disparaît (Ctrl+C, kill, crash…)
Type=simple
User=${DEV_USER}
Group=${DEV_USER}
WorkingDirectory=/home/${DEV_USER}
Environment=HOME=/home/${DEV_USER}
ExecStart=/bin/bash -c 'while true; do /usr/bin/tmux has-session -t claude-rc 2>/dev/null || /usr/bin/tmux new-session -d -s claude-rc /home/${DEV_USER}/bin/claude-rc-loop.sh; sleep 20; done'
ExecStop=/usr/bin/tmux kill-session -t claude-rc
KillMode=control-group
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT

  pct exec "$CTID" -- install -d -m 755 -o "$DEV_USER" -g "$DEV_USER" "/home/${DEV_USER}/bin"
  pct push "$CTID" "$TMPD/claude-rc.env" "/home/${DEV_USER}/.claude-rc.env" --user "$DEV_USER" --group "$DEV_USER" --perms 600
  pct push "$CTID" "$TMPD/claude-rc-loop.sh" "/home/${DEV_USER}/bin/claude-rc-loop.sh" --user "$DEV_USER" --group "$DEV_USER" --perms 755
  pct push "$CTID" "$TMPD/claude-rc.service" /etc/systemd/system/claude-rc.service --perms 644
  rm -rf "$TMPD"
  pct exec "$CTID" -- systemctl daemon-reload
  pct exec "$CTID" -- systemctl enable --now claude-rc.service
  pct exec "$CTID" -- loginctl enable-linger "$DEV_USER" || true
fi

# ============================ RÉCAPITULATIF ==================================
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
PUBKEY=$(pct exec "$CTID" -- cat "/home/${DEV_USER}/.ssh/id_ed25519.pub" 2>/dev/null || true)

cat <<MSG

==============================================================================
 ✅ Conteneur ${CTID} (${HOSTNAME_CT}) prêt — IP : ${IP}

 Connexion :      ssh ${DEV_USER}@${IP}   (ou : pct enter ${CTID} ; su - ${DEV_USER})
                  pas de mot de passe : « pct exec ${CTID} -- passwd ${DEV_USER} » pour en définir un
 MongoDB :        ${MONGO_ROOT_USER} / ${MONGO_ROOT_PWD}   (à noter, affiché une seule fois)
 GitHub CLI :     ${GH_AUTH_STATUS}${CLONE_STATUS:+
 Dépôt :          ${CLONE_STATUS}}${PUBKEY:+
 Clé SSH GitHub : ${PUBKEY}}${JIRA_STATUS:+
 Jira :           ${JIRA_STATUS}}
MSG

if [ "$RC_ENABLE" = "1" ]; then cat <<MSG

 ── Remote Control : mise en route (une seule fois) ──────────────────────────
  0. Owner de l'orga Team : activer Remote Control sur
     https://claude.ai/admin-settings/claude-code
  1. pct enter ${CTID}  →  su - ${DEV_USER}  →  tmux attach -t claude-rc
  2. Ctrl+B puis C (nouvelle fenêtre) → cd ~/${RC_DIR} → claude
     → se connecter (compte Team), faire confiance au dossier, puis /exit
  3. Ctrl+B puis 0 → attendre la relance (≤ 30 s) → répondre « y »
  4. Ctrl+B puis D pour se détacher (jamais Ctrl+C ni exit)
  5. Session « ${RC_NAME} » sur claude.ai/code ou l'appli Claude
 Service :        pct exec ${CTID} -- systemctl restart claude-rc
MSG
fi
echo " Vérifs :         java -version ; mvn -v ; docker ps ; mongosh --eval 'db.version()' ; gh auth status ; claude doctor"
echo "=============================================================================="
