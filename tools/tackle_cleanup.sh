#!/bin/bash
# Cleanup Tackle

OC_BINARY=`which oc`
NAMESPACE="konveyor-tackle"
CATSOURCE="konveyor-tackle"

${OC_BINARY} -n openshift-marketplace delete catalogsource ${CATSOURCE}
${OC_BINARY} delete project ${NAMESPACE}
${OC_BINARY} delete crd tackles.tackle.konveyor.io addons.tackle.konveyor.io
