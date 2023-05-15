#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export OPERATOR_VERSION=$(echo ${OPERATOR_SEMVER} | sed -e 's/^v//g')
export PREV_OPERATOR_VERSION=$(echo ${PREV_OPERATOR_SEMVER} | sed -e 's/^v//g')

echo "************ konveyor  operator publish command ************"

# Install tools
echo "## Install yq"
curl -L https://github.com/mikefarah/yq/releases/download/v4.13.5/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq
echo "   yq installed"

echo "## Install jq"
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -o /tmp/jq && chmod +x /tmp/jq
echo "   jq installed"

echo "## Install oc"
pushd /tmp
curl -L https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz -o openshift-client-linux.tar.gz
tar zxf openshift-client-linux.tar.gz
popd

REGISTRY_HOST="quay.io"
REGISTRY_ORG="konveyor"
UNRELEASED_SEMVER="v99.0.0"
OPERATOR_MANIFESTS="bundle/manifests"
OPERATOR_METADATA="bundle/metadata"
CSV="konveyor-operator.clusterserviceversion.yaml"

echo ${QUAY_TOKEN} | docker login ${REGISTRY_HOST} -u ${QUAY_ROBOT} --password-stdin

CO_PROJECT="community-operators-prod"
CO_PROJECT_K8S="community-operators"
CO_REPO="redhat-openshift-ecosystem/${CO_PROJECT}"
CO_REPO_K8S="k8s-operatorhub/${CO_PROJECT_K8S}"
CO_GIT="https://github.com/${CO_REPO}.git"
CO_GIT_K8S="https://github.com/${CO_REPO_K8S}.git"
CO_FORK="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${CO_PROJECT}.git"
CO_FORK_K8S="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${CO_PROJECT_K8S}.git"
CO_DIR=$(mktemp -d)
CO_DIR_K8S=$(mktemp -d)
CO_OPERATOR_DIR="${CO_DIR}/operators/konveyor-operator"
CO_OPERATOR_DIR_K8S="${CO_DIR_K8S}/operators/konveyor-operator"
CO_OPERATOR_ANNOTATIONS="${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/metadata/annotations.yaml"

if [ -z "${GITHUB_USER}" ] || [ -z "${GITHUB_TOKEN}" ] || [ -z "${GITHUB_NAME}" ] || [ -z "${GITHUB_EMAIL}" ]; then
    echo "Must set all of GITHUB_USER, GITHUB_TOKEN, GITHUB_NAME, and GITHUB_EMAIL"
    exit 1
fi

echo
echo "## Cloning community-operator-prod repo"
git clone "${CO_FORK}" "${CO_DIR}"
pushd "${CO_DIR}"
git remote add upstream "${CO_GIT}"
git fetch upstream main:upstream/main
git checkout upstream/main
git config user.name "${GITHUB_NAME}"
git config user.email "${GITHUB_EMAIL}"
echo "   ${CO_PROJECT} cloned"
popd

echo
echo "## Cloning community-operator repo"
git clone "${CO_FORK_K8S}" "${CO_DIR_K8S}"
pushd "${CO_DIR_K8S}"
git remote add upstream "${CO_GIT_K8S}"
git fetch upstream main:upstream/main
git checkout upstream/main
git config user.name "${GITHUB_NAME}"
git config user.email "${GITHUB_EMAIL}"
echo "   ${CO_PROJECT_K8S} cloned"
popd

echo
echo "## Collecting channels to be updated"
BUNDLE_CHANNELS=$(/tmp/yq eval '.annotations."operators.operatorframework.io.bundle.channels.v1"' "${OPERATOR_METADATA}/annotations.yaml")
echo "   channels to be updated are: ${BUNDLE_CHANNELS}"

PREV_OPERATOR_VERSION=${PREV_OPERATOR_VERSION:-''}
if ! [ -z "${PREV_OPERATOR_VERSION}" ]; then
  echo
  echo "## Determine operator versions we skip"
  echo "   use previous version to determine the versions we skip"
  OPERATOR_SKIPS=$(/tmp/yq eval ".spec.skips | .[]" "${CO_OPERATOR_DIR}/${PREV_OPERATOR_VERSION}/${CSV}" ||: )
  OPERATOR_SKIPS="${OPERATOR_SKIPS} konveyor-operator.v${PREV_OPERATOR_VERSION}"
echo "   skipping these operator versions: "
for version in ${OPERATOR_SKIPS}; do
    echo "    - ${version}"
done
fi

echo
echo "## Update operator manifests"
mkdir -p "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}"
cp -r "${OPERATOR_MANIFESTS}" "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}"
cp -r "${OPERATOR_METADATA}" "${CO_OPERATOR_DIR}/${OPERATOR_VERSION}"
pushd "${CO_DIR}"
git checkout -B "${OPERATOR_VERSION}"
CO_CSV="${CO_OPERATOR_DIR}/${OPERATOR_VERSION}/manifests/${CSV}"

echo "   updating operand images to use digest"
# Grab all of the images from the relatedImages and get their digest sha
for full_image in $(/tmp/yq eval '.spec.relatedImages[] | .image' "${CO_CSV}"); do
    image=${full_image%:*}
    image_name=${image#*/}

    # Mirror image
     mirror_image_name="${REGISTRY_ORG}/${image_name#*/}"
     if ! [[ "$full_image" =~ "${REGISTRY_HOST}/${REGISTRY_ORG}/".* ]]; then

    	full_mirror_image="${REGISTRY_HOST}/${mirror_image_name}:v${OPERATOR_VERSION}"
    	echo "   mirroring image ${full_image} -> ${full_mirror_image}"
        /tmp/oc image mirror "${full_image}" "${full_mirror_image}" || {
        	echo "ERROR Unable to mirror image"
        	exit 1
     	}	
     fi

    digest=$(curl -G "https://${REGISTRY_HOST}/api/v1/repository/${mirror_image_name}/tag/?specificTag=v${OPERATOR_VERSION}" | \
        /tmp/jq -e -r '
            .tags[]
            | select((has("expiration") | not))
            | .manifest_digest')

    # Fail if digest empty
    [[ -z ${digest} ]] && false
    sed -i "s,${full_image},${REGISTRY_HOST}/${mirror_image_name}@${digest},g" "${CO_CSV}"
done

echo "   updating operator image to use digest"
full_operator_image=$(/tmp/yq eval '.spec.install.spec.deployments[0].spec.template.spec.containers[0] | .image' "${CO_CSV}")
operator_image=${full_operator_image%:*}
operator_image_name=${operator_image#*/}
operator_digest=$(curl -G "https://${REGISTRY_HOST}/api/v1/repository/${operator_image_name}/tag/?specificTag=v${OPERATOR_VERSION}" | \
        /tmp/jq -e -r '
            .tags[]
            | select((has("expiration") | not))
            | .manifest_digest')
export operator_digest_fqin=${operator_image}@${operator_digest}
/tmp/yq eval --exit-status --inplace \
    '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image |= strenv(operator_digest_fqin)' "${CO_CSV}"
/tmp/yq eval --exit-status --inplace '.metadata.annotations["containerImage"] |= strenv(operator_digest_fqin)' "${CO_CSV}"

echo "   update createdAt time"
CREATED_AT=$(date +"%Y-%m-%dT%H:%M:%SZ") /tmp/yq eval --exit-status --inplace '.metadata.annotations["createdAt"] |= strenv(CREATED_AT)' "${CO_CSV}" 

echo "   update operator version"
sed -i "s/${UNRELEASED_SEMVER}/${OPERATOR_VERSION}/" "${CO_CSV}"

echo "   adding replaces"
if [ -z "${PREV_OPERATOR_VERSION}" ]; then
    /tmp/yq eval --exit-status --inplace 'del(.spec.replaces)' "${CO_CSV}"
else
v="konveyor-operator.v${PREV_OPERATOR_VERSION}" \
    /tmp/yq eval --exit-status --inplace \
    '.spec.replaces |= strenv(v)' "${CO_CSV}"
fi

echo "   adding skipRange"
    /tmp/yq eval --exit-status --inplace \
    '.metadata.annotations["olm.skipRange"] |= ">=0.0.0 <" + strenv(OPERATOR_VERSION)' "${CO_CSV}"

if ! [ -z "${PREV_OPERATOR_VERSION}" ]; then
  echo "   adding spec.skips"
  for version in ${OPERATOR_SKIPS}; do
      v="${version}" \
        /tmp/yq eval --exit-status --inplace \
        '.spec.skips |= . + [strenv(v)]' "${CO_CSV}"
  done
fi

echo "   updating version"
    /tmp/yq eval --exit-status --inplace \
    '.spec.version |= strenv(OPERATOR_VERSION)' "${CO_CSV}"

    /tmp/yq eval --exit-status --inplace \
    '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env[] |= select(.name == "VERSION") .value=strenv(OPERATOR_VERSION)' "${CO_CSV}"

echo "   update annotations channel"
for c in ${BUNDLE_CHANNELS//,/ }; do
    /tmp/yq eval --inplace '.annotations["operators.operatorframework.io.bundle.channels.v1"] |= strenv(OPERATOR_CHANNEL)' ${CO_OPERATOR_ANNOTATIONS}
    /tmp/yq eval --inplace '.annotations["operators.operatorframework.io.bundle.channel.default.v1"] |= strenv(OPERATOR_CHANNEL)' ${CO_OPERATOR_ANNOTATIONS}
done

echo "   remove scorecard annotations"
/tmp/yq eval --inplace 'del(.annotations["operators.operatorframework.io.test.mediatype.v1"])' ${CO_OPERATOR_ANNOTATIONS}
/tmp/yq eval --inplace 'del(.annotations["operators.operatorframework.io.test.config.v1"])' ${CO_OPERATOR_ANNOTATIONS}

echo "   copy updated operator files to K8s repo and submit PR"
cp -r ${CO_OPERATOR_DIR}/. ${CO_OPERATOR_DIR_K8S}
pushd "${CO_DIR_K8S}"
git checkout -B "${OPERATOR_VERSION}"
git add --all
git commit -s -m "konveyor-operator.v${OPERATOR_VERSION}"
git push --set-upstream --force origin HEAD
# Create PR
curl "https://api.github.com/repos/${CO_REPO_K8S}/pulls" --user "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST \
    --data '{"title": "'"$(git log -1 --format=%s)"'", "base": "main", "body": "An automated PR to update konveyor-operator to v'"${OPERATOR_VERSION}"'", "head": "'"${GITHUB_USER}:${OPERATOR_VERSION}"'"}'
popd

echo "   add minimum version to annotations"
/tmp/yq eval --inplace '.annotations["com.redhat.openshift.versions"] = "v4.9" | .annotations["com.redhat.openshift.versions"] style="double"' ${CO_OPERATOR_ANNOTATIONS}

echo
echo "## Submit PR to community operators"
echo "   commit changes"
git add --all
git commit -s -m "konveyor-operator.v${OPERATOR_VERSION}"
git push --set-upstream --force origin HEAD

echo "   submit PR"
# Create PR
curl "https://api.github.com/repos/${CO_REPO}/pulls" --user "${GITHUB_USER}:${GITHUB_TOKEN}" -X POST \
    --data '{"title": "'"$(git log -1 --format=%s)"'", "base": "main", "body": "An automated PR to update konveyor-operator to v'"${OPERATOR_VERSION}"'", "head": "'"${GITHUB_USER}:${OPERATOR_VERSION}"'"}'
popd

echo "## Done ##"
