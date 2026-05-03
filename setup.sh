#!/usr/bin/env bash
#
# Usage:
#   ./setup.sh
#   FORCE_REINSTALL=1 ./setup.sh    # force install even if up-to-date
#
# Optional env vars for CI/non-interactive use:
#   export SKIP_SHELL_INIT=1           # skip writing dynamic hook into shell rc
#   export NO_WSL_WARNING=1            # suppress /mnt (WSL) warning
#   export MAMBA_CHANNEL="conda-forge" # where to install conda-lock (default: conda-forge)

# ===== Portable strict mode (bash + zsh) =====
if [ -n "${BASH_VERSION:-}" ]; then
  set -euo pipefail
else
  set -eu
  set -o pipefail 2>/dev/null || true
fi

on_error() {
  printf "\n\033[0;31mError:\033[0m setup.sh failed. Check the output above.\n"
  exit 1
}
if [ -n "${BASH_VERSION:-}" ]; then
  trap on_error ERR
else
  trap on_error ZERR
fi

# ===== Portable yes/no prompting (TTY-safe) =====
confirm() {
  # usage: confirm "Prompt (y/n): " [default_y_or_n]
  # prints 'y' or 'n' to stdout
  local __prompt="$1"
  local __def="${2:-n}"
  local __ans=""

  # If no terminal is available (CI), return default
  if ! [ -r /dev/tty ]; then
    printf '%s\n' "$__def"
    return 0
  fi

  while :; do
    # print prompt to the terminal (not stdout) so it isn't swallowed by $(...)
    printf "%s" "$__prompt" > /dev/tty

    # read from the terminal (not stdin), works for both bash and zsh
    IFS= read -r __ans < /dev/tty

    [ -z "$__ans" ] && __ans="$__def"
    __ans=$(printf %s "$__ans" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    case "$__ans" in
      y|yes) printf 'y\n'; return 0 ;;
      n|no)  printf 'n\n'; return 0 ;;
      *)     printf "Please type y or n and press Enter.\n" > /dev/tty ;;
    esac
  done
}

# =======================
# Config
# =======================
ENV_NAME="GraphLearning"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd -P)"   # BSD/GNU-safe
cd "$REPO_ROOT"

MAMBA_DIR=".micromamba"
MAMBA_BIN="$MAMBA_DIR/bin/micromamba"

ENV_YML="environment.yml"
LOCK_META="conda-lock.yml"                 # used by `conda-lock install`
LOCK_HASH_FILE=".conda-lock.input.sha256"  # tracks env.yml hash + conda-lock version

LOG_DIR="$REPO_ROOT/.setup_logs"
mkdir -p "$LOG_DIR"

# =======================
# Read local_env.sh
# =======================
if [ -f "$REPO_ROOT/local_env.sh" ]; then
  # shellcheck disable=SC1090
  . "$REPO_ROOT/local_env.sh"
else
  printf "[bootstrap] ⚠️ Expected local_env.sh at %s but not found.\n" "$REPO_ROOT/local_env.sh"
fi

# =======================
# Platform detection
# =======================
UNAME_S=$(uname -s)
UNAME_M=$(uname -m)
case "${UNAME_S}-${UNAME_M}" in
  Linux-x86_64)    MAMBA_PLATFORM="linux-64" ;;
  Linux-aarch64)   MAMBA_PLATFORM="linux-aarch64" ;;
  Darwin-x86_64)   MAMBA_PLATFORM="osx-64" ;;
  Darwin-arm64)    MAMBA_PLATFORM="osx-arm64" ;;
  *) printf "Unsupported platform: %s-%s\n" "$UNAME_S" "$UNAME_M"; exit 1 ;;
esac

# =======================
# RC target (bash & zsh only)
# =======================
detect_rc_target() {
  local zrc="${ZDOTDIR:-$HOME}/.zshrc"
  local brc="$HOME/.bashrc"
  if [ -n "${ZSH_VERSION:-}" ]; then
    echo "$zrc"; return 0
  elif [ -n "${BASH_VERSION:-}" ]; then
    echo "$brc"; return 0
  fi
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$zrc" ;;
    bash) echo "$brc" ;;
    *)    echo "$zrc" ;;
  esac
}

ensure_bash_profile_sources_bashrc() {
  # macOS/login shells often read ~/.bash_profile but not ~/.bashrc
  local brc="$HOME/.bashrc"
  local bprof="$HOME/.bash_profile"
  [ -f "$bprof" ] || return 0
  if ! grep -qE '(^|\s)\. .*\.bashrc|source .*\.bashrc' "$bprof"; then
    {
      printf "\n# Added by setup.sh: load ~/.bashrc for interactive settings\n"
      printf "[ -f %s ] && . %s\n" "$brc" "$brc"
    } >> "$bprof"
    printf "[bootstrap] 🔗 Ensured ~/.bash_profile sources ~/.bashrc\n"
  fi
}

# =======================
# Helpers
# =======================
hash_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sanitize_conda_env() {
  unset CONDA_PKGS_DIRS CONDA_PREFIX CONDA_EXE MAMBA_EXE
  export MAMBA_ROOT_PREFIX="$REPO_ROOT/$MAMBA_DIR"
  export CONDA_PKGS_DIRS="$REPO_ROOT/.conda_pkgs"
  mkdir -p "$CONDA_PKGS_DIRS"
  export PATH="$MAMBA_ROOT_PREFIX/bin:$PATH"
}

ensure_conda_lock() {
  if "$MAMBA_BIN" run -n base conda-lock --version >/dev/null 2>&1; then return 0; fi
  printf "\n[bootstrap] 🔧 Installing conda-lock into micromamba base...\n"
  "$MAMBA_BIN" install -y -q -n base -c "${MAMBA_CHANNEL:-conda-forge}" conda-lock
  if ! "$MAMBA_BIN" run -n base conda-lock --version >/dev/null 2>&1; then
    printf "[bootstrap] ❌ Failed to install conda-lock into base.\n"
    exit 1
  fi
  printf "[bootstrap] ✅ conda-lock installed.\n"
}

clean_mamba_caches() {
  "$MAMBA_BIN" clean --all -y >/dev/null 2>&1 || true
}

# ========= Lock consistency =========
locks_are_current() {
  [ -f "$LOCK_META" ] || return 1
  local env_sum tool_ver saved
  env_sum=$(hash_cmd "$ENV_YML")
  if "$MAMBA_BIN" run -n base conda-lock --version >/dev/null 2>&1; then
    tool_ver=$("$MAMBA_BIN" run -n base conda-lock --version | tr -d '\n')
  else
    tool_ver=$({ conda-lock --version 2>/dev/null || echo "unknown"; } | tr -d '\n')
  fi
  saved=$(cat "$LOCK_HASH_FILE" 2>/dev/null || echo "")
  [ "$saved" = "${env_sum}:${tool_ver}" ] || return 1
  [ "$LOCK_META" -nt "$ENV_YML" ] || return 1
  return 0
}

write_lock_fingerprint() {
  local env_sum tool_ver
  env_sum=$(hash_cmd "$ENV_YML")
  if "$MAMBA_BIN" run -n base conda-lock --version >/dev/null 2>&1; then
    tool_ver=$("$MAMBA_BIN" run -n base conda-lock --version | tr -d '\n')
  else
    tool_ver=$({ conda-lock --version 2>/dev/null || echo "unknown"; } | tr -d '\n')
  fi
  echo "${env_sum}:${tool_ver}" > "$LOCK_HASH_FILE"
}

explain_lock_state_if_outdated() {
  if [ ! -f "$LOCK_META" ]; then
    printf "[lock] 🔒 No lock metadata (conda-lock.yml) found.\n"
  elif [ "$LOCK_META" -ot "$ENV_YML" ]; then
    printf "[lock] 🔒 %s is newer than conda-lock.yml; will refresh.\n" "$ENV_YML"
  else
    printf "[lock] 🔒 Lock fingerprint (env hash or conda-lock version) changed; will refresh.\n"
  fi
}

# ---------- Env state helpers ----------
env_marker_path() {
  echo "$MAMBA_ROOT_PREFIX/envs/$ENV_NAME/conda-meta/jslab-conda-lock.sha256"
}
env_exists() {
  [ -d "$MAMBA_ROOT_PREFIX/envs/$ENV_NAME" ] && [ -d "$MAMBA_ROOT_PREFIX/envs/$ENV_NAME/conda-meta" ]
}
env_matches_lock() {
  locks_are_current || return 1
  env_exists || return 1
  local cur saved marker
  cur=$(cat "$LOCK_HASH_FILE" 2>/dev/null || echo "")
  marker=$(env_marker_path)
  saved=$(cat "$marker" 2>/dev/null || echo "")
  [ -n "$cur" ] && [ "$cur" = "$saved" ]
}
write_env_fingerprint() {
  local marker cur
  marker=$(env_marker_path)
  mkdir -p "$(dirname "$marker")"
  cur=$(cat "$LOCK_HASH_FILE" 2>/dev/null || echo "")
  [ -n "$cur" ] && echo "$cur" > "$marker"
}

# =======================
# Progress bar / spinner
# =======================
_run_quiet_with_progress() {
  # Usage: _run_quiet_with_progress "label" /path/to/cmd args...
  local label="$1"; shift
  local safe_label log width i filled empty pid rc
  safe_label=$(printf "%s" "$label" | tr ' /' '__')
  log="$LOG_DIR/${safe_label}.log"

  ( "$@" >"$log" 2>&1 ) & pid=$!

  width=28; i=0
  printf "%s " "$label"
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i+1) % (width+1) ))
    filled=$(printf '%*s' "$i" '' | tr ' ' '#')
    empty=$(printf '%*s' "$((width - i))" '' | tr ' ' ' ')
    printf "\r%s [%s%s]" "$label" "$filled" "$empty"
    sleep 0.12
  done
  wait "$pid"; rc=$?
  if [ $rc -eq 0 ]; then
    printf "\r%s [%s] ✓\n" "$label" "$(printf '%*s' "$width" '' | tr ' ' '#')"
  else
    printf "\r%s [FAILED]\n" "$label"
    printf "  ↳ See log: %s\n" "$log"
    printf "  --- last 60 lines ---\n"
    tail -n 60 "$log" || true
    return "$rc"
  fi
  return 0
}

# =======================
# Dynamic, relocatable shell init
# =======================
cleanup_old_mamba_lines() {
  local SHELL_RC="$1"
  [ -n "$SHELL_RC" ] || return 0
  mkdir -p "$(dirname "$SHELL_RC")"
  [ -f "$SHELL_RC" ] || { printf "[bootstrap] (init) No existing %s to clean\n" "$SHELL_RC"; return 0; }

  local ts tmp tmp2 tmpdir
  ts="$(date +%Y%m%d%H%M%S)"
  cp "$SHELL_RC" "$SHELL_RC.bak.$ts" || true

  # --- use system temp dir rather than the repo/current dir ---
  tmpdir="${TMPDIR:-/tmp}"
  tmp="$(mktemp "$tmpdir/jslab-rc.XXXXXXXX")"
  tmp2="$(mktemp "$tmpdir/jslab-rc.XXXXXXXX")"

  awk 'BEGIN{skip=0}
       /# >>> jslab-mamba dynamic init >>>/ {skip=1; next}
       /# <<< jslab-mamba dynamic init <<</ {skip=0; next}
       {
         if (skip) next
         s=$0; comment=0
         if (s ~ /micromamba[[:space:]]+shell[[:space:]]+hook/) comment=1
         else if (s ~ /PROMPT_COMMAND=.*micromamba/) comment=1
         else if (s ~ /MAMBA_ROOT_PREFIX=.*\.micromamba/) comment=1
         else if (s ~ /\.micromamba\/bin/) comment=1
         else if (index(s,"${path[") && index(s,"]}")) comment=1
         if (comment) print "# " s; else print s
       }' "$SHELL_RC" > "$tmp"

  # strip empty if/then/fi blocks
  awk '
    function flush(){ for(i=1;i<=n;i++) print buf[i]; n=0 }
    BEGIN{inblk=0;n=0}
    /^[[:space:]]*if[[:space:]].*;[[:space:]]*then[[:space:]]*$/ {inblk=1;n=0;buf[++n]=$0; next}
    inblk{
      buf[++n]=$0
      if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) {
        empty=1
        for(i=2;i<n;i++){ if (buf[i] !~ /^[[:space:]]*(#.*)?$/) { empty=0; break } }
        if (!empty) flush()
        inblk=0; n=0; next
      }
      next
    }
    {print}
  ' "$tmp" > "$tmp2"

  mv "$tmp2" "$SHELL_RC"
  rm -f "$tmp"
  printf "[bootstrap] 🧹 Cleaned old micromamba lines in %s (backup: %s)\n" "$SHELL_RC" "$SHELL_RC.bak.$ts"
}


install_dynamic_init() {
  # args: rc path, target shell (bash|zsh)
  local SHELL_RC="$1"
  local target="$2"
  local BEGIN_MARK="# >>> jslab-mamba dynamic init >>>"
  local END_MARK="# <<< jslab-mamba dynamic init <<<"

  mkdir -p "$(dirname "$SHELL_RC")"
  [ -f "$SHELL_RC" ] || : > "$SHELL_RC"

  if grep -qF "$BEGIN_MARK" "$SHELL_RC" 2>/dev/null; then
    printf "[bootstrap] ✅ Dynamic micromamba init already present in %s\n" "$SHELL_RC"
    return 0
  fi

  {
    printf '%s\n' "$BEGIN_MARK"
    case "$target" in
      zsh)
        cat <<'EOF'
# Dynamic micromamba init for zsh (robust to frameworks & VS Code).
__jslab_find_repo_root() {
  REPLY=""
  if command -v git >/dev/null 2>&1; then
    REPLY=$(git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null || echo "")
  fi
  if [[ -z "$REPLY" ]]; then
    local d="${PWD:-.}"
    while [[ "$d" != "/" ]]; do
      if [[ -d "$d/.micromamba" ]]; then REPLY="$d"; return 0; fi
      d="${d:h}"
    done
  fi
}
__jslab_mamba_init_if_repo() {
  local root=""
  REPLY=""; __jslab_find_repo_root; root="$REPLY"
  [[ -n "$root" && -x "$root/.micromamba/bin/micromamba" ]] || return 0
  export MAMBA_ROOT_PREFIX="$root/.micromamba"

  # Add to zsh's path array exactly once (PATH mirrors $path automatically)
  if (( ${path[(Ie)"$MAMBA_ROOT_PREFIX/bin"]} == 0 )); then
    path=( "$MAMBA_ROOT_PREFIX/bin" $path )
  fi

  # Initialize shell hook once per session
  if [[ -z ${__JSLAB_MAMBA_ZSH_INIT_DONE+x} ]]; then
    eval "$("$MAMBA_ROOT_PREFIX/bin/micromamba" shell hook --shell zsh)"
    typeset -g __JSLAB_MAMBA_ZSH_INIT_DONE=1
  fi
}

# Install hooks once: run on directory change and before each prompt
if [[ -z ${__JSLAB_MAMBA_ZSH_HOOKS_INSTALLED+x} ]]; then
  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd  __jslab_mamba_init_if_repo
  add-zsh-hook precmd __jslab_mamba_init_if_repo
  typeset -g __JSLAB_MAMBA_ZSH_HOOKS_INSTALLED=1
fi

# Run immediately for current shell (covers starting inside the repo)
__jslab_mamba_init_if_repo
EOF
        ;;
      bash)
        cat <<'EOF'
# Dynamic micromamba init for bash.
__jslab_find_repo_root() {
  REPLY=""
  if command -v git >/dev/null 2>&1; then
    REPLY=$(git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null || echo "")
  fi
  if [ -z "$REPLY" ]; then
    local d="${PWD:-.}"
    while [ "$d" != "/" ]; do
      if [ -d "$d/.micromamba" ]; then REPLY="$d"; return 0; fi
      d="$(dirname "$d")"
    done
  fi
}
__jslab_mamba_init_if_repo() {
  local root=""
  REPLY=""; __jslab_find_repo_root; root="$REPLY"
  [ -n "$root" ] || return 0
  if [ -x "$root/.micromamba/bin/micromamba" ]; then
    export MAMBA_ROOT_PREFIX="$root/.micromamba"
    case ":$PATH:" in *":$MAMBA_ROOT_PREFIX/bin:"*) : ;; *) export PATH="$MAMBA_ROOT_PREFIX/bin:$PATH" ;; esac
    if ! type _micromamba_shell_func >/dev/null 2>&1; then
      eval "$("$MAMBA_ROOT_PREFIX/bin/micromamba" shell hook --shell bash)"
    fi
  fi
}
__jslab_mamba_init_if_repo
if ! type __jslab_cd_orig >/dev/null 2>&1; then
  __jslab_cd_orig() { builtin cd "$@"; }
  cd() { __jslab_cd_orig "$@" && __jslab_mamba_init_if_repo; }
fi
case ";${PROMPT_COMMAND:-};" in
  *"__jslab_mamba_init_if_repo"*) : ;;
  *) PROMPT_COMMAND="__jslab_mamba_init_if_repo${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
esac
EOF
        ;;
    esac
    printf '%s\n' "$END_MARK"
  } >> "$SHELL_RC"

  printf "[bootstrap] 📎 Installed dynamic micromamba init into %s\n" "$SHELL_RC"
}

# =======================
# WSL warning for /mnt
# =======================
if [ -z "${NO_WSL_WARNING:-}" ] && [[ "$REPO_ROOT" == /mnt/* ]]; then
  printf "\n\033[0;33m⚠️  Warning:\033[0m Running from a Windows-mounted path in WSL:\n"
  printf "    %s\n" "$REPO_ROOT"
  printf "    This may cause permission issues or poor performance.\n"
  confirm_mnt=$(confirm $'Continue anyway? (\033[1;36my/n\033[0m): ' n)
  if [ "$confirm_mnt" != "y" ]; then
    printf "Exiting. Move the repo into the WSL filesystem and retry.\n"
    exit 1
  fi
fi

# =======================
# Micromamba bootstrap (repo-local)
# =======================
if [ ! -x "$MAMBA_BIN" ]; then
  printf "[bootstrap] 🔧 micromamba not found — installing...\n"
  mkdir -p "$MAMBA_DIR"
  # Download to temp file first — BSD tar (macOS) cannot extract a specific
  # path from a piped stream; saving to disk first avoids this limitation.
  _mamba_tmp="$(mktemp /tmp/micromamba.XXXXXX.tar.bz2)"
  curl -Ls "https://micro.mamba.pm/api/micromamba/${MAMBA_PLATFORM}/latest" -o "$_mamba_tmp"
  tar -xj -C "$MAMBA_DIR" -f "$_mamba_tmp" bin/micromamba
  rm -f "$_mamba_tmp"
  printf "[bootstrap] ✅ micromamba installed.\n"
else
  printf "[bootstrap] ✅ micromamba already installed.\n"
fi

# Put repo-local micromamba on PATH for this run
export MAMBA_ROOT_PREFIX="$REPO_ROOT/$MAMBA_DIR"
export PATH="$MAMBA_ROOT_PREFIX/bin:$PATH"

# =======================
# Generate/refresh cross-platform lock (from environment.yml)
# =======================
generate_locks_if_needed() {
  if [ ! -f "$ENV_YML" ]; then
    printf "❌ %s not found. Cannot proceed.\n" "$ENV_YML"
    exit 1
  fi

  if locks_are_current; then
    printf "[lock] 🔒 conda-lock.yml is up-to-date with %s — no regeneration needed.\n" "$ENV_YML"
    return 0
  fi

  explain_lock_state_if_outdated
  printf "\n[lock] 🔒 Regenerating cross-platform lock \033[1mfrom environment.yml\033[0m (not from installed env).\n"

  sanitize_conda_env
  ensure_conda_lock
  clean_mamba_caches

  # NOTE: osx-arm64 dropped because r-huge, r-glasso, r-didimputation, r-estimatr
  # lack Apple Silicon builds on conda-forge. Apple Silicon users can use Rosetta
  # (osx-64 env) or install missing packages directly via R.
  printf "[lock] 🧊 Generating conda-lock.yml for platforms: linux-64, osx-64 …\n"
  _run_quiet_with_progress "[lock] Building lockfile" \
    "$MAMBA_BIN" run -n base conda-lock lock --micromamba -f "$ENV_YML" \
      -p linux-64 -p osx-64

  write_lock_fingerprint
  printf "[lock] ✅ Lockfile updated: conda-lock.yml (cross-platform)\n"
}

# =======================
# Create/update environment (always from lock)
# =======================
create_env_from_lock_prompted() {
  if [ -z "${FORCE_REINSTALL:-}" ] && env_matches_lock; then
    printf "\n[env] ✅ Environment \033[1;36m%s\033[0m is up-to-date with \033[1mconda-lock.yml\033[0m — skipping install.\n" "$ENV_NAME"
    return 0
  fi

  printf "\n[env] 📦 Ready to create/update environment \033[1;36m%s\033[0m from \033[1mconda-lock.yml\033[0m.\n" "$ENV_NAME"
  go=$(confirm $'[env] Proceed? (\033[1;36my/n\033[0m): ' n)
  if [ "$go" != "y" ]; then
    printf "[env] ⏭️  Skipping environment creation.\n"
    return 0
  fi

  sanitize_conda_env
  ensure_conda_lock
  "$MAMBA_BIN" run -n base conda-lock install --name "$ENV_NAME" --micromamba "$LOCK_META"

  write_env_fingerprint
  printf "[env] ✅ Environment created/updated from lock.\n"
}

# =======================
# External symlinks (from local_env.sh)
# =======================
# local_env.sh must define:
#   EXTERNAL_NAMES=( "dropbox" ... )
#   EXTERNAL_PATHS=( "/mnt/c/Users/juanc/Dropbox" ... )
# Creates symlinks under $EXTERNAL_LINK_ROOT/<name> (default: externals/).

EXTERNAL_LINK_ROOT="${EXTERNAL_LINK_ROOT:-externals}"

_ext_log() { printf "%s\n" "$*"; }
_ext_die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

_ext_link_one() {
  # $1 = link (relative to repo), $2 = target
  local link_rel="$1" target="$2" link parent
  case "$link_rel" in /*) link="$link_rel" ;; *) link="$REPO_ROOT/$link_rel" ;; esac
  parent="$(dirname "$link")"
  [ -d "$parent" ] || mkdir -p "$parent"

  if [ ! -e "$target" ]; then
    _ext_log "[externals] ⚠️  Target does not exist yet: $target (link will still be created)"
  fi

  if [ -L "$link" ]; then
    _ext_log "[externals] ↺ Replacing symlink: $link -> $target"
    ln -sfn "$target" "$link"
  elif [ -e "$link" ]; then
    _ext_die "[externals] Refusing to overwrite non-symlink at $link (remove it and re-run)."
  else
    _ext_log "[externals] + Linking: $link -> $target"
    ln -s "$target" "$link"
  fi
}

create_externals() {
  # With `set -u`, referencing an unset array errors. Guard with declare -p.
  local n_names n_paths
  if declare -p EXTERNAL_NAMES >/dev/null 2>&1; then
    n_names=${#EXTERNAL_NAMES[@]}
  else
    n_names=0
  fi
  if declare -p EXTERNAL_PATHS >/dev/null 2>&1; then
    n_paths=${#EXTERNAL_PATHS[@]}
  else
    n_paths=0
  fi

  if [ "$n_names" -eq 0 ]; then
    printf "[externals] (skip) No externals configured in local_env.sh.\n"
    return 0
  fi
  if [ "$n_names" -ne "$n_paths" ]; then
    _ext_die "[externals] EXTERNAL_NAMES and EXTERNAL_PATHS length mismatch ($n_names vs $n_paths)."
  fi

  local i name tgt link_rel
  for ((i=0; i<n_names; i++)); do
    name="${EXTERNAL_NAMES[$i]}"
    tgt="${EXTERNAL_PATHS[$i]}"
    [ -n "$name" ] && [ -n "$tgt" ] || _ext_die "[externals] Empty name/target at index $i."
    case "$name" in *"/"*) _ext_die "[externals] Name must not contain '/': $name" ;; esac
    link_rel="$EXTERNAL_LINK_ROOT/$name"
    _ext_link_one "$link_rel" "$tgt"
  done

  printf "[externals] ✅ External linking done.\n"
}

# =======================
# Flow
# =======================
printf "\n\033[1m== micromamba + conda-lock setup (cross-platform lock, relocatable init) ==\033[0m\n"

RC_TARGET="$(detect_rc_target)"
cleanup_old_mamba_lines "$RC_TARGET"
case "$RC_TARGET" in
  */.zshrc) install_dynamic_init "$RC_TARGET" "zsh" ;;
  */.bashrc) install_dynamic_init "$RC_TARGET" "bash"; ensure_bash_profile_sources_bashrc ;;
  *)        install_dynamic_init "$RC_TARGET" "bash"; ensure_bash_profile_sources_bashrc ;;
esac

generate_locks_if_needed
if env_matches_lock; then
  printf "[env] 🔍 Detected existing env matching current lock; will skip install unless forced.\n"
fi
create_env_from_lock_prompted
create_externals

# =======================
# biber (LaTeX bibliography backend)
# =======================
# tectonic ships biblatex but not biber. We pin a specific upstream binary in
# setup_biber.sh; see that script for the version-compatibility rationale.
if [ -x "$REPO_ROOT/setup_biber.sh" ]; then
  printf "\n[biber] 📚 Installing pinned biber binary for biblatex...\n"
  "$REPO_ROOT/setup_biber.sh" || printf "[biber] ⚠️  setup_biber.sh failed; LaTeX bibliography will not compile.\n"
fi

printf "\n✅ Setup complete.\n"
printf "🔁 Open a new shell or \033[1msource your rc\033[0m to apply the dynamic init.\n"
printf "👉 When you \033[1mcd into this repo\033[0m (regardless of its name/path), micromamba will auto-initialize.\n"
printf "   Then run: \033[1;36mmicromamba activate %s\033[0m\n" "$ENV_NAME"
