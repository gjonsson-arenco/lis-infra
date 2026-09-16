#!/usr/bin/env bash
#
# Muestra el último commit local de cada repo del stack bajo $LIS_ROOT, junto
# con si tiene cambios sin commitear o commits que difieren del upstream.
#
# Para qué: saber de un vistazo qué versión de cada servicio está desplegada
# en el server sin entrar repo por repo. Sólo lee; no hace fetch ni toca nada,
# así que el "behind" es respecto del último fetch que haya hecho redeploy.sh.
#
# Uso:
#   ./scripts/last-commits.sh
#   LIS_ROOT=/otra/ruta ./scripts/last-commits.sh
#
# Desde la máquina local, sin copiar nada:
#   ssh usuario@server 'bash -s' < scripts/last-commits.sh

set -uo pipefail

LIS_ROOT="${LIS_ROOT:-/opt/lis}"

# -maxdepth 3 alcanza a los adapters, que viven un nivel más abajo
# (lis-adapters/lis-adapter-labcore).
find "$LIS_ROOT" -maxdepth 3 -type d -name .git 2>/dev/null | sort | while read -r gitdir; do
  repo="$(dirname "$gitdir")"
  printf '\n\e[1;36m== %s\e[0m\n' "${repo#"$LIS_ROOT"/}"

  git -C "$repo" log -1 --date=iso-local \
    --format='  hash    %h  (%H)%n  branch  %D%n  author  %an <%ae>%n  date    %ad (%ar)%n  subject %s' 2>/dev/null \
    || { echo '  (sin commits)'; continue; }

  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
  [ "$dirty" -gt 0 ] && printf '  \e[33mdirty   %s archivos modificados\e[0m\n' "$dirty"

  if upstream=$(git -C "$repo" rev-parse --abbrev-ref '@{u}' 2>/dev/null); then
    read -r behind ahead < <(git -C "$repo" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
    [ "${ahead:-0}" -gt 0 ]  && printf '  \e[33mahead   %s commits sin pushear a %s\e[0m\n' "$ahead" "$upstream"
    [ "${behind:-0}" -gt 0 ] && printf '  \e[33mbehind  %s commits detrás de %s (según último fetch)\e[0m\n' "$behind" "$upstream"
  fi
done
