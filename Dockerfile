ARG OPERATOR_SDK_VERSION=v1.42.3
FROM quay.io/operator-framework/ansible-operator:$OPERATOR_SDK_VERSION

USER 0
COPY tools/upgrades/migrate-pathfinder-assessments.py /usr/local/bin/migrate-pathfinder-assessments.py
COPY tools/upgrades/jwt.sh /usr/local/bin/jwt.sh
RUN microdnf -y install openssl && microdnf clean all
RUN echo -e "[almalinux9-appstream]" \
 "\nname = almalinux9-appstream" \
 "\nbaseurl = https://repo.almalinux.org/almalinux/9/AppStream/\$basearch/os/" \
 "\nenabled = 1" \
 "\ngpgcheck = 0" > /etc/yum.repos.d/almalinux.repo
RUN microdnf -y module enable postgresql:15 && microdnf -y install postgresql python3.12-psycopg2 && microdnf clean all
RUN python3 -m ensurepip && pip3 install --no-cache-dir jmespath && pip3 install --no-cache-dir --upgrade pyasn1>=0.6.4
USER 1001

COPY requirements.yml ${HOME}/requirements.yml
RUN ansible-galaxy collection install -r ${HOME}/requirements.yml \
 && chmod -R ug+rwx ${HOME}/.ansible

COPY watches.yaml ${HOME}/watches.yaml
COPY roles/ ${HOME}/roles/
COPY playbooks/ ${HOME}/playbooks/
