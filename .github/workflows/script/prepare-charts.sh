#!/usr/bin/env bash
# Suggested .github/workflows/scripts/prepare-charts.sh for longhorn/charts.
#
# Based on the script of longhorn/charts#290 (a7f6b01c). Changes against it, each marked
# "CHANGED" below:
#   1. take a release type (release or rc) and, for rc, a number: the appVersion of the two copies
#      is then written as v<A.B.C>-rc.<N>, the form that cargueiro wants
#   2. drop the upstream kubeVersion field, as the committed Rancher chart does (rancher/charts#9383),
#      because the catalog.cattle.io/kube-version annotation replaces it
#   3. fail if an image is left that is not mirrored
#   4. give longhorn-crd the README that the committed Rancher chart has
#   5. adapt the README of longhorn for the Rancher UI (no helm install, no values tables)
#   6. log what it does: a few lines always, and much more with DEBUG=true
#
# Prepares the Longhorn charts of a release for the ship-family-staged action of
# rancher/charts. It takes the chart that Longhorn releases, charts/longhorn, and makes
# from it the two charts of the Rancher catalog, in <output dir>:
#
#   longhorn      the chart, with the annotations the catalog needs, the images of
#                 Longhorn under the names that Rancher mirrors them as, and the roles
#                 for Rancher users, without the CRDs
#   longhorn-crd  the CRDs, as a chart of their own
#
# The action stamps, checks, packages and pushes the copies, so the source stays as it is.
#
# Usage: prepare-charts.sh <chart dir> <output dir> [release|rc] [rc number]
#   e.g. prepare-charts.sh release/charts/longhorn "$RUNNER_TEMP/charts" release
#        prepare-charts.sh release/charts/longhorn "$RUNNER_TEMP/charts" rc 2
#
#   release  (the default) the appVersion is left as it is, and it must not be a candidate
#   rc       the appVersion of the two charts of the copy becomes v<A.B.C>-rc.<N>: an existing
#            -rc1 or -rc.1 suffix is replaced, and a release such as v1.13.1 gets one. The
#            number is required, a positive integer: the first candidate is 1, and one for
#            testing or fixing is 2, 3, and so on. The image tags are not touched.
#
# Environment (the first two are required):
#   RANCHER_VERSION  the Rancher minor the charts are for, such as 2.16
#   KUBE_VERSION     the Kubernetes versions the release supports, with both bounds, such
#                    as ">= 1.34.0-0 < 1.37.0-0"
#   DEBUG            true to log the arguments, the tools, every step of the preparation and
#                    the files of the result. The logs go to stderr and hold no secret: this
#                    script reads none.
#
# Requires yq (mikefarah, v4) on PATH.
set -euo pipefail

# CHANGED (6): log() always, debug() only with DEBUG=true. Both go to stderr.
DEBUG=${DEBUG:-false}
log() { echo "prepare-charts: $*" >&2; }
debug() { if [ "$DEBUG" = "true" ]; then echo "prepare-charts [debug]: $*" >&2; fi; }

SRC=${1:?usage: $0 <chart dir> <output dir> [release|rc] [rc number]}
OUT=${2:?usage: $0 <chart dir> <output dir> [release|rc] [rc number]}
RELEASE_TYPE=${3:-release}
RC_NUMBER=${4:-}
RANCHER_VERSION=${RANCHER_VERSION:?RANCHER_VERSION is required, such as 2.16}
KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION is required, such as \">= 1.34.0-0 < 1.37.0-0\"}
debug "arguments: chart dir='$SRC' output dir='$OUT' release type='$RELEASE_TYPE' rc number='${RC_NUMBER}'"
debug "environment: RANCHER_VERSION='$RANCHER_VERSION' KUBE_VERSION='$KUBE_VERSION' DEBUG='$DEBUG'"
debug "tools: $(yq --version 2>&1 | head -1); $(bash --version | head -1); sed: $(sed --version 2>&1 | head -1)"

if ! [[ "$RANCHER_VERSION" =~ ^2\.([0-9]+)$ ]]; then
  echo "Error: RANCHER_VERSION $RANCHER_VERSION must look like 2.16" >&2
  exit 1
fi
RANCHER_MINOR="${BASH_REMATCH[1]}"
RANCHER_RANGE=">= 2.${RANCHER_MINOR}.0-0 < 2.$((RANCHER_MINOR + 1)).0-0"
debug "rancher-version annotation will be '$RANCHER_RANGE'"

if ! [[ "$KUBE_VERSION" =~ ^\>=\ [0-9]+\.[0-9]+\.[0-9]+-0\ \<\ [0-9]+\.[0-9]+\.[0-9]+-0$ ]]; then
  echo "Error: KUBE_VERSION '$KUBE_VERSION' must look like \">= 1.34.0-0 < 1.37.0-0\"" >&2
  exit 1
fi

for file in Chart.yaml values.yaml questions.yaml templates/crds.yaml templates/_helpers.tpl; do
  if [ ! -f "$SRC/$file" ]; then
    echo "Error: there is no $file in $SRC" >&2
    exit 1
  fi
done
APP_VERSION=$(yq '.appVersion' "$SRC/Chart.yaml")
SOURCE_APP_VERSION="$APP_VERSION"
log "source chart $(yq '.name' "$SRC/Chart.yaml") version $(yq '.version' "$SRC/Chart.yaml"), appVersion $SOURCE_APP_VERSION, release type $RELEASE_TYPE${RC_NUMBER:+ $RC_NUMBER}"
debug "source files: $(cd "$SRC" && find . -type f | sort | tr '\n' ' ')"

# CHANGED (1): the appVersion of the two charts of the catalog. Cargueiro works the chart
# version out from it (111.Z.W+up<appVersion without the v>), and its version rules want a
# candidate as -rc.N, while Longhorn writes v1.13.1-rc1. So the release type decides:
#   release  leave it as it is; a candidate here is a mistake, and it is refused
#   rc       v<A.B.C>-rc.<N>, whatever suffix it had
# The image tags are not touched: they stay as they are on Docker Hub.
case "$RELEASE_TYPE" in
  release)
    if [[ "$APP_VERSION" == *-* ]]; then
      echo "Error: appVersion $APP_VERSION of $SRC/Chart.yaml has a suffix, so it is not a release. Use the rc type with a number." >&2
      exit 1
    fi
    ;;
  rc)
    if ! [[ "$RC_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
      echo "Error: the rc type needs a number, a positive integer, such as 1 (got '$RC_NUMBER')" >&2
      exit 1
    fi
    if ! [[ "$APP_VERSION" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-rc\.?[0-9]+)?$ ]]; then
      echo "Error: appVersion $APP_VERSION of $SRC/Chart.yaml must look like v1.13.1 or v1.13.1-rc1 to make a candidate of it" >&2
      exit 1
    fi
    APP_VERSION="v${BASH_REMATCH[1]}-rc.${RC_NUMBER}"
    ;;
  *)
    echo "Error: the release type '$RELEASE_TYPE' must be release or rc" >&2
    exit 1
    ;;
esac
log "appVersion of the two charts: $APP_VERSION (the source has $SOURCE_APP_VERSION)"

rm -rf "$OUT/longhorn" "$OUT/longhorn-crd"
mkdir -p "$OUT/longhorn-crd/templates"
cp -r "$SRC" "$OUT/longhorn"
debug "copied $SRC to $OUT/longhorn"
# CHANGED (1), continued: the appVersion in the copy only (it changes only for rc). The label
# app.kubernetes.io/version of the chart follows it, and the image tags do not.
APP="$APP_VERSION" yq -i '.appVersion = strenv(APP)' "$OUT/longhorn/Chart.yaml"

# Two files of the release that are not part of the chart in the catalog: the readme for
# OpenShift and the template its readme is made from.
rm -f "$OUT/longhorn/ocp-readme.md" "$OUT/longhorn/README.md.gotmpl"

# The CRDs are a chart of their own in the catalog, installed first and kept out of the
# chart, so that they outlive it and are not removed with it.
mv "$OUT/longhorn/templates/crds.yaml" "$OUT/longhorn-crd/templates/crds.yaml"
cp "$SRC/templates/_helpers.tpl" "$OUT/longhorn-crd/templates/_helpers.tpl"
debug "moved templates/crds.yaml to longhorn-crd ($(wc -l <"$OUT/longhorn-crd/templates/crds.yaml") lines) and copied _helpers.tpl"
# The version is a placeholder: the action stamps the final one (111.Z.W+up<appVersion>).
cat >"$OUT/longhorn-crd/Chart.yaml" <<YAML
apiVersion: v1
name: longhorn-crd
description: Installs the CRDs for longhorn.
version: ${APP_VERSION#v}
appVersion: ${APP_VERSION}
annotations:
  catalog.cattle.io/certified: rancher
  catalog.cattle.io/hidden: "true"
  catalog.cattle.io/namespace: longhorn-system
  catalog.cattle.io/release-name: longhorn-crd
YAML
# CHANGED (4): the committed longhorn-crd chart of rancher/charts has this README.
cat >"$OUT/longhorn-crd/README.md" <<'MD'
# longhorn-crd
A Rancher chart that installs the CRDs used by longhorn.
MD

# The annotations that the catalog reads. The chart that Longhorn releases has none of
# them, and a release that has others keeps them.
RANGE="$RANCHER_RANGE" KUBE="$KUBE_VERSION" yq -i '
  .annotations."catalog.cattle.io/auto-install" = "longhorn-crd=match" |
  .annotations."catalog.cattle.io/certified" = "rancher" |
  .annotations."catalog.cattle.io/display-name" = "Longhorn" |
  .annotations."catalog.cattle.io/kube-version" = strenv(KUBE) |
  .annotations."catalog.cattle.io/namespace" = "longhorn-system" |
  .annotations."catalog.cattle.io/permits-os" = "linux,windows" |
  .annotations."catalog.cattle.io/provides-gvr" = "longhorn.io/v1beta1" |
  .annotations."catalog.cattle.io/rancher-version" = strenv(RANGE) |
  .annotations."catalog.cattle.io/release-name" = "longhorn" |
  .annotations."catalog.cattle.io/type" = "cluster-tool"
' "$OUT/longhorn/Chart.yaml"
# CHANGED (2): the Rancher chart in rancher/charts#9383 has no kubeVersion; the annotation
# above is what the catalog and the checks read. Delete this line to keep the upstream one.
yq -i 'del(.kubeVersion)' "$OUT/longhorn/Chart.yaml"
debug "annotations of longhorn: $(yq -o=json -I=0 '.annotations' "$OUT/longhorn/Chart.yaml")"
debug "kubeVersion field of longhorn after the delete: '$(yq '.kubeVersion // "none"' "$OUT/longhorn/Chart.yaml")'"

# Rancher mirrors the images of Longhorn, which come from another organization, as
# rancher/mirrored-longhornio-<image>, and the catalog pulls them from there.
# The helm.sh/images annotation that some releases have lists them too, and stamp keeps
# an annotation that exists, so it follows the values.
debug "images under longhornio/ before the sed: values.yaml=$(grep -c 'longhornio/' "$OUT/longhorn/values.yaml" || true) questions.yaml=$(grep -c 'longhornio/' "$OUT/longhorn/questions.yaml" || true) Chart.yaml=$(grep -c 'longhornio/' "$OUT/longhorn/Chart.yaml" || true)"
sed -i 's|longhornio/|rancher/mirrored-longhornio-|g' \
  "$OUT/longhorn/values.yaml" "$OUT/longhorn/questions.yaml" "$OUT/longhorn/Chart.yaml"
log "images mirrored: $(grep -c 'rancher/mirrored-longhornio-' "$OUT/longhorn/values.yaml" || true) repositories in values.yaml"

# CHANGED (3): an image that the sed did not reach would be pulled from Docker Hub by the
# catalog. README.md is documentation and is left as it is.
if grep -rnE '(^|[^-])longhornio/' "$OUT/longhorn/values.yaml" "$OUT/longhorn/questions.yaml" \
  "$OUT/longhorn/Chart.yaml" "$OUT/longhorn/templates"; then
  echo "Error: an image is still under longhornio/ and is not mirrored" >&2
  exit 1
fi

# CHANGED (5): the README of the release tells how to install with helm repo add
# https://charts.longhorn.io and how to uninstall with helm uninstall, and it lists every
# value. In the Rancher catalog the chart is installed from the Apps page, so, as the
# committed chart of rancher/charts#9383 does, drop the Installation and Values sections and
# replace the Uninstallation section with the steps for the Rancher UI. The sections are
# found by their headings: stop if the README of a release has changed its layout.
readme="$OUT/longhorn/README.md"
for heading in '## Installation' '## Uninstallation' '## Values'; do
  if ! grep -qxF "$heading" "$readme"; then
    echo "Error: there is no '$heading' section in $SRC/README.md, so the README cannot be adapted for Rancher" >&2
    exit 1
  fi
done
awk '/^## Installation$/ { exit } { print }' "$readme" >"$readme.new"
cat >>"$readme.new" <<'MD'
## Uninstallation

To prevent Longhorn from being accidentally uninstalled (which leads to data lost), we introduce a new setting, deleting-confirmation-flag. If this flag is **false**, the Longhorn uninstallation job will fail. Set this flag to **true** to allow Longhorn uninstallation. You can set this flag using setting page in Longhorn UI or `kubectl -n longhorn-system patch -p '{"value": "true"}' --type=merge lhs deleting-confirmation-flag`

To prevent damage to the Kubernetes cluster, we recommend deleting all Kubernetes workloads using Longhorn volumes (PersistentVolume, PersistentVolumeClaim, StorageClass, Deployment, StatefulSet, DaemonSet, etc).

From Rancher Cluster Explorer UI, navigate to Apps page, delete app `longhorn` then app `longhorn-crd` in Installed Apps tab.

---
Please see [link](https://github.com/longhorn/longhorn) for more information.
MD
mv "$readme.new" "$readme"
debug "README.md of longhorn: $(wc -l <"$SRC/README.md") lines in the source, $(wc -l <"$readme") lines after"

# The roles that give the users of Rancher access to the resources of Longhorn: the
# plural names of the CRDs of the release, and their status, so the list follows the
# CRDs of each release.
resources=$(grep -E '^    plural: ' "$OUT/longhorn-crd/templates/crds.yaml" | awk '{print $2}' | sort -u |
  awk '{ printf "%s\"%s\", \"%s/status\"", sep, $1, $1; sep = ", " }')
if [ -z "$resources" ]; then
  echo "Error: no CRD found in $SRC/templates/crds.yaml" >&2
  exit 1
fi
debug "CRD plural names for the roles: $(echo "$resources" | grep -o '"[a-z]*", ' | wc -l) resources, each with its /status"
role() { # role <name> <aggregate-to> <verbs>
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: "longhorn-$1"
  labels:
    rbac.authorization.k8s.io/aggregate-to-$2: "true"
rules:
- apiGroups: [ "longhorn.io" ]
  resources: [${resources}]
  verbs: [ $3 ]
YAML
}
{
  role admin admin '"*"'
  echo "---"
  role edit edit '"*"'
  echo "---"
  role view view '"get", "list", "watch"'
} >"$OUT/longhorn/templates/userroles.yaml"

log "done: $OUT/longhorn ($(find "$OUT/longhorn" -type f | wc -l) files) and $OUT/longhorn-crd ($(find "$OUT/longhorn-crd" -type f | wc -l) files)"
debug "files of $OUT:"
if [ "$DEBUG" = "true" ]; then
  (cd "$OUT" && find . -type f | sort) | sed 's/^/  /' >&2
  debug "files that differ from the source chart (names only):"
  { diff -rq "$SRC" "$OUT/longhorn" || true; } | sed 's/^/  /' >&2
  debug "Chart.yaml of longhorn-crd:"
  sed 's/^/  /' "$OUT/longhorn-crd/Chart.yaml" >&2
fi
