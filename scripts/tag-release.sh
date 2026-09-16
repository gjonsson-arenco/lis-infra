#!/usr/bin/env bash
#
# Marca el HEAD actual de CADA repo del stack con el mismo tag, para que "qué
# había desplegado en tal fecha" sea una pregunta a git y no a la memoria: el
# delta entre dos deploys es `git log tagA..tagB` en cada repo, y de eso vive
# release-notes.sh.
#
# Se taggean todos los repos, no sólo los que cambiaron en el deploy: el tag
# es una foto del stack completo. Un repo sin cambios entre dos tags tiene
# delta vacío, que es exactamente lo que queremos saber.
#
# Lo llama redeploy.sh al final de un deploy exitoso. A mano sirve para:
#   - bootstrap: taggear lo que está desplegado hoy, antes del primer deploy
#     con release-notes (`./scripts/tag-release.sh cebac/2026-09-10`)
#   - retaggear si el push falló y se arregló la deploy key.
#
# Uso:
#   ./scripts/tag-release.sh                 # cebac/<fecha>-<hhmm>
#   ./scripts/tag-release.sh cebac/2026-09-10
#   TAG_PUSH=false ./scripts/tag-release.sh  # sólo local, sin push
#
# El push a origin es best-effort: si la deploy key del server es de sólo
# lectura, el tag queda local en el server y release-notes.sh lo lee igual
# por ssh. Sale con 1 si algún tag no se pudo crear (no si falló el push).

set -uo pipefail

LIS_ROOT="${LIS_ROOT:-/opt/lis}"
TAG="${1:-cebac/$(date +%Y-%m-%d-%H%M)}"
TAG_PUSH="${TAG_PUSH:-true}"

failed=0
unpushed=()

# -maxdepth 3 alcanza a los adapters (lis-adapters/lis-adapter-labcore).
while read -r gitdir; do
  repo="$(dirname "$gitdir")"
  name="${repo#"$LIS_ROOT"/}"

  if git -C "$repo" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    if [ "$(git -C "$repo" rev-parse "refs/tags/$TAG^{commit}")" = "$(git -C "$repo" rev-parse HEAD)" ]; then
      echo "==> $name: $TAG ya apunta a HEAD"
    else
      echo "ERROR: $name: $TAG ya existe y apunta a otro commit — no lo piso." >&2
      failed=1
    fi
    continue
  fi

  # Tag liviano a propósito: no necesita user.name/email configurados en el
  # server y la fecha del deploy ya va en el nombre.
  if ! git -C "$repo" tag "$TAG"; then
    echo "ERROR: $name: no se pudo crear el tag." >&2
    failed=1
    continue
  fi
  echo "==> $name: $TAG -> $(git -C "$repo" rev-parse --short HEAD)"

  if [ "$TAG_PUSH" = true ] && ! git -C "$repo" push -q origin "refs/tags/$TAG" 2>/dev/null; then
    unpushed+=("$name")
  fi
done < <(find "$LIS_ROOT" -maxdepth 3 -type d -name .git 2>/dev/null | sort)

if [ ${#unpushed[@]} -gt 0 ]; then
  echo "ADVERTENCIA: el tag quedó sólo local en: ${unpushed[*]}" >&2
  echo "             (deploy key sin escritura?). release-notes.sh lo lee por ssh igual." >&2
fi

exit $failed
