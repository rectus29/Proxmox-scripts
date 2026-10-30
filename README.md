# proxmox-scripts

Scripts d'administration pour Proxmox VE.

## `setup-claude-dev-lxc.sh`

Crée un conteneur LXC Debian prêt pour du développement Java / Spring / MongoDB / Docker, avec Claude Code lancé automatiquement en **Remote Control** (pilotable depuis claude.ai/code ou l'appli Claude).

### Contenu du conteneur

| Élément | Détail |
|---|---|
| Système | Debian 13 (trixie) par défaut, ou 12 (bookworm) — conteneur non privilégié, `nesting` + `keyctl`, démarrage au boot |
| Java | Temurin 17 / 21 / 25 (dépôt Adoptium) + Maven (dépôt Debian) |
| Docker | Docker CE, `docker compose`, buildx — utilisable sans sudo |
| MongoDB | Conteneur Docker `mongo` sur `127.0.0.1:27017`, mot de passe root aléatoire ; `mongosh` est un wrapper vers celui de l'image, connecté par défaut |
| Git / GitHub | git, git-lfs, GitHub CLI ; authentification par token et clonage d'un dépôt en option |
| Jira (optionnel) | Variables `JIRA_*` exportées pour l'API REST Jira Cloud, accès vérifié à la création |
| Claude Code | Installé pour l'utilisateur `dev`, avec un `~/.claude/CLAUDE.md` global (environnement + règles git) |
| Remote Control | Service systemd `claude-rc` qui maintient une session tmux `claude-rc` exécutant `claude remote-control` |

L'utilisateur `dev` a sudo sans mot de passe. Les clés de `/root/.ssh/authorized_keys` de l'hôte lui sont copiées pour l'accès SSH.

### Prérequis

- Être **root sur l'hôte Proxmox** (Shell du nœud).
- Un stockage actif acceptant les conteneurs (`rootdir`) et un accès Internet depuis le bridge choisi.
- Optionnel : un **token GitHub fine-grained** (`github_pat_…`) avec accès en lecture/écriture au contenu et aux PR du dépôt visé.
- Pour Remote Control avec un compte Team/Enterprise : un owner de l'organisation doit l'activer sur <https://claude.ai/admin-settings/claude-code>.

### Utilisation

Mode interactif (assistant `whiptail`, modes *simple* ou *avancé*) :

```bash
./setup-claude-dev-lxc.sh
```

Mode non interactif, en passant les paramètres par l'environnement :

```bash
NO_WIZARD=1 \
HOSTNAME_CT=claude-dev \
GH_TOKEN=github_pat_xxx GH_REPO=mon-org/mon-repo \
GIT_NAME="Claude Bot" GIT_EMAIL=claude-bot@example.com \
./setup-claude-dev-lxc.sh
```

En mode interactif, les variables passées dans l'environnement deviennent les valeurs proposées par défaut.

### Connexion à Jira

Optionnelle. Créer un token d'API sur <https://id.atlassian.com/manage-profile/security/api-tokens>, puis répondre « oui » à l'étape Jira de l'assistant, ou passer les variables :

```bash
JIRA_URL=https://mon-org.atlassian.net \
JIRA_EMAIL=moi@example.com \
JIRA_API_TOKEN=xxx \
JIRA_PROJECT=PROJ \
./setup-claude-dev-lxc.sh
```

`JIRA_URL`, `JIRA_EMAIL` et `JIRA_API_TOKEN` vont ensemble : le script refuse de démarrer s'il en manque une. Elles sont écrites dans `~/.dev-env`, donc disponibles dans les shells de `dev` et pour Claude en Remote Control. Le `CLAUDE.md` global explique à Claude comment appeler l'API REST v3 avec ces variables. À la fin, le script appelle `/rest/api/3/myself` pour vérifier l'accès et affiche le résultat.

Test manuel dans le conteneur :

```bash
curl -sS -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_URL/rest/api/3/myself" | jq .displayName
```

Le token donne les mêmes droits que le compte qui l'a créé : utiliser de préférence un compte dédié aux droits limités.

### Paramètres

| Variable | Défaut | Rôle |
|---|---|---|
| `CTID` | prochain ID libre | ID du conteneur |
| `HOSTNAME_CT` | `claude-dev` | Nom d'hôte |
| `DEBIAN_VERSION` | `13` | `12` (bookworm) ou `13` (trixie) |
| `STORAGE` | premier stockage compatible | Stockage du disque |
| `TEMPLATE_STORAGE` | `local` | Stockage des templates |
| `DISK_GB` / `CORES` / `RAM_MB` / `SWAP_MB` | `64` / `4` / `8192` / `2048` | Ressources |
| `BRIDGE` | `vmbr0` | Bridge réseau |
| `IP_CONF` | `dhcp` | ou IP fixe, ex. `192.168.1.50/24,gw=192.168.1.1` |
| `DEV_USER` | `dev` | Utilisateur de développement |
| `JAVA_VERSION` | `21` | `17`, `21` ou `25` |
| `MONGO_IMAGE` | `mongo:8` | Image Docker MongoDB |
| `MONGO_ROOT_USER` / `MONGO_ROOT_PWD` | `admin` / aléatoire | Identifiants root Mongo |
| `SSH_PUBKEY_FILE` | `/root/.ssh/authorized_keys` | Clés autorisées copiées pour `dev` |
| `GIT_NAME` / `GIT_EMAIL` | `Claude Bot` / `claude-bot@example.com` | Auteur des commits |
| `GIT_DEFAULT_BRANCH` | `main` | Branche protégée dans les règles de `CLAUDE.md` |
| `GH_TOKEN` | — | Token GitHub (sinon `gh auth login` plus tard) |
| `GH_REPO` | — | Dépôt `org/repo` à cloner dans `~/workspace` |
| `GEN_SSH_KEY` | `auto` | Génère une clé SSH GitHub ; `auto` = seulement sans token |
| `JIRA_URL` | — | Site Jira Cloud, ex. `https://mon-org.atlassian.net` |
| `JIRA_EMAIL` | — | Email du compte Atlassian propriétaire du token |
| `JIRA_API_TOKEN` | — | Token d'API Atlassian |
| `JIRA_PROJECT` | — | Clé du projet Jira par défaut (optionnel) |
| `RC_ENABLE` | `1` | Active le service Remote Control |
| `RC_NAME` | nom d'hôte | Nom de la session dans claude.ai/code |
| `RC_DIR` | `workspace` ou le dépôt cloné | Dossier de travail, relatif au home |
| `RC_SPAWN` | `same-dir` | `same-dir`, `worktree` ou `session` |
| `RC_PERMISSION_MODE` | `default` | `default`, `acceptEdits` ou `plan` |
| `NO_WIZARD` | `0` | `1` pour désactiver l'assistant |

### Après la création

Le script affiche l'IP, les identifiants MongoDB (**affichés une seule fois**, à noter) et l'état de GitHub.

Première connexion de Claude (une seule fois) :

1. `pct enter <CTID>` → `su - dev` → `tmux attach -t claude-rc`
2. `Ctrl+B` puis `C` (nouvelle fenêtre) → `cd ~/<RC_DIR>` → `claude` → se connecter, faire confiance au dossier, puis `/exit`
3. `Ctrl+B` puis `0` → attendre la relance (≤ 30 s) → répondre `y`
4. `Ctrl+B` puis `D` pour se détacher (jamais `Ctrl+C` ni `exit`)
5. La session apparaît sur claude.ai/code ou dans l'appli Claude

Vérifications dans le conteneur :

```bash
java -version ; mvn -v ; docker ps ; mongosh --eval 'db.version()' ; gh auth status ; claude doctor
```

Relancer le service : `pct exec <CTID> -- systemctl restart claude-rc`

### Fichiers créés dans le conteneur

| Chemin | Rôle |
|---|---|
| `~/infra/mongo/docker-compose.yml` | Définition du conteneur MongoDB |
| `~/.dev-env` | `PATH`, `JAVA_HOME`, `SPRING_DATA_MONGODB_URI`, variables `JIRA_*` (chargé par `.bashrc`) |
| `~/.local/bin/mongosh` | Wrapper vers le `mongosh` de l'image Mongo |
| `~/.claude/CLAUDE.md` | Instructions globales pour Claude |
| `~/.claude-rc.env`, `~/bin/claude-rc-loop.sh` | Configuration et boucle Remote Control |
| `/etc/systemd/system/claude-rc.service` | Service superviseur de la session tmux |

### Sécurité

- Le mot de passe MongoDB est stocké en clair dans `~/infra/mongo/docker-compose.yml` et `~/.dev-env` (chmod 600). Mongo n'écoute que sur `127.0.0.1`.
- Le token GitHub transite par un fichier temporaire effacé avec `shred` ; il est ensuite géré par `gh`.
- Le token Jira est stocké en clair dans `~/.dev-env` (chmod 600) et visible par Claude via l'environnement.
- `dev` a sudo sans mot de passe : le conteneur est un environnement de dev, pas un serveur exposé.

### En cas d'échec

Si le conteneur n'a pas d'accès à `deb.debian.org`, le script s'arrête juste après la création. Corriger le bridge, la passerelle ou le DNS, puis supprimer le conteneur avant de relancer :

```bash
pct destroy <CTID> --purge
```
