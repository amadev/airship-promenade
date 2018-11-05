# Disable overwriting our resolv.conf
#
resolvconf --disable-updates

CURATED_DIRS=(
    /etc/kubernetes
    /var/lib/etcd
)

for DIR in "${CURATED_DIRS[@]}"; do
    mkdir -p "${DIR}"
    chmod 700 "${DIR}"
done

# Unpack prepared files into place
#
set +x
log
log === Extracting prepared files ===
{{ decrypt_setup_command }}
echo "{{ encrypted_tarball | b64enc }}" | base64 -d | {{ decrypt_command }} | tar -zxv -C / | tee /etc/promenade-manifest
{{ decrypt_teardown_command }}
set -x

for DIR in "${CURATED_DIRS[@]}"; do
    chmod -R go-rwx "${DIR}"
done

# Adding apt repositories
#
set +x
log
log === Adding APT Keys===
set -x
{%- for key in config.get_path('HostSystem:packages.keys', []) %}
apt-key add - <<"ENDKEY"
{{ key }}
ENDKEY
{%- endfor %}

# Disable swap
#
set +x
log
log === Disabling swap ===
set -x
swapoff -a
sed --in-place '/\bswap\b/d' /etc/fstab

# Set proxy variables
#
set +x
log
log === Setting proxy variables ===
set -x
export http_proxy={{ config['KubernetesNetwork:proxy.url'] | default('', true) }}
export https_proxy={{ config['KubernetesNetwork:proxy.url'] | default('', true) }}
export no_proxy={{ config.get(kind='KubernetesNetwork') | fill_no_proxy }}


# Install system packages
#
set +x
log
log === Installing system packages ===
set -x

if [ "{{ config['HostSystem:packages.mini_mirror.enabled'] }}" = "true" ]; then
    DOWNLOAD_DIR=/cache/mini-mirror
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"
    curl -L -f {{ config['HostSystem:packages.mini_mirror.download_url'] }}  -o mini-mirror.tar
    tar -xf mini-mirror.tar
    cd $DOWNLOAD_DIR/$(du -s * | sort -nr | head | cut -f2)
    tar -xf layer.tar
    dpkg -i $(find . -name 'docker*.deb')
    cat "$DOWNLOAD_DIR/mini-mirror.tar" | docker load
    docker run --detach --publish '{{ config['HostSystem:packages.mini_mirror.port'] }}:80' --image {{ config['HostSystem:packages.mini_mirror.enabled'] }}
    URL=localhost:{{ config['HostSystem:packages.mini_mirror.port'] }}
    mv /etc/apt/sources.list /etc/apt/sources.list.backup
    curl -s $URL/aptly_repo_signing.key | apt-key add -
    echo "deb http://$URL xenial main" > /etc/apt/sources.list
    echo "deb-src http://$URL xenial main" >> /etc/apt/sources.list
    apt-get update
fi

end=$(($(date +%s) + 600))
while true; do
    if ! apt-get update; then
        now=$(date +%s)
        if [[ ${now} -gt ${end} ]]; then
            log Failed to update apt-cache.
            exit 1
        fi
        sleep 10
    else
        break
    fi
done

end=$(($(date +%s) + 600))
while true; do
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            {%- for package in config['HostSystem:packages.additional'] | default([]) %}
            {{ package }} \
            {%- endfor %}
            {{ config['HostSystem:packages.required.docker'] }} \
            {{ config['HostSystem:packages.required.socat'] }}; then
        now=$(date +%s)
        if [[ ${now} -gt ${end} ]]; then
            log Failed to install apt packages.
            exit 1
        fi
        sleep 10
    else
        break
    fi
done

# Start core processes
#
set +x
log
log === Starting Docker and Kubelet ===
set -x
systemctl daemon-reload
systemctl restart docker || true
systemctl enable kubelet
systemctl restart kubelet
