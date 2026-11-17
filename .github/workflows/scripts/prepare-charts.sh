#!/usr/bin/env bash
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
# Usage: prepare-charts.sh <chart dir> <output dir>
#   e.g. prepare-charts.sh release/charts/longhorn "$RUNNER_TEMP/charts"
#
# Environment (both required):
#   RANCHER_VERSION  the Rancher minor the charts are for, such as 2.16
#   KUBE_VERSION     the Kubernetes versions the release supports, with both bounds, such
#                    as ">= 1.34.0-0 < 1.37.0-0"
#
# Requires yq (mikefarah, v4) on PATH.
set -euo pipefail

SRC=${1:?usage: $0 <chart dir> <output dir>}
OUT=${2:?usage: $0 <chart dir> <output dir>}
RANCHER_VERSION=${RANCHER_VERSION:?RANCHER_VERSION is required, such as 2.16}
KUBE_VERSION=${KUBE_VERSION:?KUBE_VERSION is required, such as \">= 1.34.0-0 < 1.37.0-0\"}

if ! [[ "$RANCHER_VERSION" =~ ^2\.([0-9]+)$ ]]; then
  echo "Error: RANCHER_VERSION $RANCHER_VERSION must look like 2.16" >&2
  exit 1
fi
RANCHER_MINOR="${BASH_REMATCH[1]}"
RANCHER_RANGE=">= 2.${RANCHER_MINOR}.0-0 < 2.$((RANCHER_MINOR + 1)).0-0"

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

rm -rf "$OUT/longhorn" "$OUT/longhorn-crd"
mkdir -p "$OUT/longhorn-crd/templates"
cp -r "$SRC" "$OUT/longhorn"

# Two files of the release that are not part of the chart in the catalog: the readme for
# OpenShift and the template its readme is made from.
rm -f "$OUT/longhorn/ocp-readme.md" "$OUT/longhorn/README.md.gotmpl"

# The CRDs are a chart of their own in the catalog, installed first and kept out of the
# chart, so that they outlive it and are not removed with it.
mv "$OUT/longhorn/templates/crds.yaml" "$OUT/longhorn-crd/templates/crds.yaml"
cp "$SRC/templates/_helpers.tpl" "$OUT/longhorn-crd/templates/_helpers.tpl"
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

# Rancher mirrors the images of Longhorn, which come from another organization, as
# rancher/mirrored-longhornio-<image>, and the catalog pulls them from there.
# The helm.sh/images annotation that some releases have lists them too, and stamp keeps
# an annotation that exists, so it follows the values.
sed -i 's|longhornio/|rancher/mirrored-longhornio-|g' \
  "$OUT/longhorn/values.yaml" "$OUT/longhorn/questions.yaml" "$OUT/longhorn/Chart.yaml"

# The roles that give the users of Rancher access to the resources of Longhorn: the
# plural names of the CRDs of the release, and their status, so the list follows the
# CRDs of each release.
resources=$(grep -E '^    plural: ' "$OUT/longhorn-crd/templates/crds.yaml" | awk '{print $2}' | sort -u |
  awk '{ printf "%s\"%s\", \"%s/status\"", sep, $1, $1; sep = ", " }')
if [ -z "$resources" ]; then
  echo "Error: no CRD found in $SRC/templates/crds.yaml" >&2
  exit 1
fi
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
