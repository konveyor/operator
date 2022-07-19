#!/bin/bash
# Quay.io repo names must match what is provisioned by user
# PROJECT_ROOT assumes running script from tools repo subdir
# CSV_PATH is relative to PROJECT_ROOT
# All objects are created inside PROJECT_NS namespace for OCP and k8s clusters

PROJECT_ROOT="../"
CSV_PATH="bundle/manifests/tackle-operator.clusterserviceversion.yaml"
REQ_BINS="opm oc docker podman operator-sdk"
OPERATOR_REPO="tackle2-operator"
BUNDLE_REPO="tackle2-operator-bundle"
INDEX_REPO="tackle2-operator-index"
CATALOG_NS="konveyor-tackle"
PROJECT_NS="konveyor-tackle"
TAG="latest"
NAME="Tackle"

function usage () {
echo
echo "Valid arguments for $(basename $0):"
echo
echo -e "\t-n : Quay ORG used for ${NAME} development repos (required)"
echo -e "\t-o : Build and push operator image"
echo -e "\t-b : Build and push bundle image"
echo -e "\t-i : Build and push index image"
echo -e "\t-c : Create custom ${NAME} catalogsource"
echo -e "\t-d : Deploy development ${NAME} for testing"
echo
echo "$(basename $0) helps a developer test a ${NAME} operator in a Kubernetes or OpenShift environment. The script uses operator-sdk to build and publish operator, bundle and index images to Quay. Once this is done, developers can deploy and test and validate using a custom catalog source."
echo
exit 1
}

if [ $# -eq 0 ]; then
  usage
fi

# Parse options and set run conditions
while getopts 'n:obicdh' opt
do
    case $opt in
        n)
            QUAY_NS="${OPTARG}"
            ;;
        b)
	    RUN_BUNDLE=true
            ;;
        i)
            RUN_INDEX=true
            ;;
        o)
            RUN_OPERATOR=true
            ;;
        c)
            RUN_CATALOG=true
	    ;;
        d)
            RUN_DEPLOYMENT=true
	    ;;
        h)
            usage
            ;;
        *)  usage
            ;;
    esac
done

#
# Sanity checks
#

echo
echo "##### Sanity Checks #####"
echo
for bin in $REQ_BINS; do
        which $bin &>/dev/null
        if [ $? -ne 0 ]; then
                echo "Required $bin missing in path, exiting..."
                echo
                exit 1
        fi
done

# Safety check if QUAY_NS set to konveyor, NEVER build/push to upstream production repos

if [ "${QUAY_NS}" == "konveyor" ]; then
       echo "${NAME} Quay production repos (quay.io/${QUAY_NS}) should NEVER be used for development/testing, exiting..."
       echo
       exit 1
fi

echo "All requirements Ok"

# Check if we are running on k8s or OCP clusters

oc get apiservices v1.route.openshift.io 1>/dev/null

if [ $? -ne 0 ]; then
	CLI_BIN=kubectl
else
	CLI_BIN=oc
fi

# CWD is project root
pushd ${PROJECT_ROOT} 1>/dev/null

# Must process options passed in correct sequence regardless of positional getopts args

if [ ! -z ${RUN_OPERATOR} ]; then
	echo
	echo "##### Building and pushing Operator #####"
	echo
	make docker-build docker-push IMG=quay.io/${QUAY_NS}/${OPERATOR_REPO}:${TAG}
fi

if [ ! -z ${RUN_BUNDLE} ]; then
	echo
	echo "##### Building and pushing Bundle #####"
	echo
	# Must patch bundle CSV with target custom operator image first, assumes main branch latest tag
	sed -i "s/quay.io\/konveyor\/tackle2-operator:latest/quay.io\/${QUAY_NS}\/tackle2-operator:${TAG}/" ${CSV_PATH}
	operator-sdk bundle validate ./bundle && make bundle-build bundle-push BUNDLE_IMG=quay.io/${QUAY_NS}/${BUNDLE_REPO}:${TAG}
fi

if [ ! -z ${RUN_INDEX} ]; then
	echo
	echo "##### Building and pushing Index #####"
	echo
	opm index add --bundles quay.io/${QUAY_NS}/${BUNDLE_REPO}:${TAG} --tag quay.io/${QUAY_NS}/${INDEX_REPO}:${TAG} && podman push quay.io/${QUAY_NS}/${INDEX_REPO}:${TAG}
fi

if [ ! -z  ${RUN_CATALOG} ]; then
	echo
	echo "##### Creating custom Catalog #####"
	echo
        ${CLI_BIN} create namespace ${PROJECT_NS}
	cat << EOF | ${CLI_BIN} apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${PROJECT_NS}
  namespace: ${PROJECT_NS}
spec:
  displayName: ${NAME} Development
  publisher: Konveyor
  sourceType: grpc
  image: quay.io/${QUAY_NS}/${INDEX_REPO}:${TAG}
EOF
fi

if [ ! -z ${RUN_DEPLOYMENT} ]; then
	echo
	echo "##### Deploying ${NAME} #####"
	echo
	${CLI_BIN} apply -f tackle-k8s-dev.yaml
fi
