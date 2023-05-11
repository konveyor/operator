ARG OPERATOR_SDK_VERSION=v1.28.1
FROM quay.io/operator-framework/ansible-operator:$OPERATOR_SDK_VERSION

COPY requirements.yml ${HOME}/requirements.yml
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && chmod -R ug+rwx ${HOME}/.ansible

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
COPY playbooks/ ${HOME}/playbooks/
