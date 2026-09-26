#!/bin/bash
# Build this tree for Ubuntu 18.04 arm64 (nvnano: Jetson Nano, L4T r32.7.6),
# whose distro sshd is stuck at 7.6 with no post-quantum key exchange.
# Deployed by roles/infra/openssh_upstream in the manergi ansible repo.
#
# Runs inside arm64v8/ubuntu:18.04, from the top of the source tree:
#
#   docker run --rm -v "$PWD":/src -w /src arm64v8/ubuntu:18.04 ci/build-bionic-arm64.sh
#
# (on a non-arm64 host add --platform linux/arm64 and RUN_TESTS=0; the
# regress suite takes hours emulated.)
#
# Building on bionic is the point: the binaries link against glibc 2.27,
# libssl1.1 (ESM-patched on the host) and libpam 1.1.8, which is what nvnano
# has. A build on a newer distro would not start there.
#
# Release tags carry the pre-generated configure, so no autoreconf. The tree
# at tag V_10_5_P1 is identical to the signed openssh-10.5p1.tar.gz.
#
# Output in out/: openssh-<ver>-bionic-arm64.tar.gz (a tree rooted at /,
# containing only /opt/openssh/<ver>), its .sha256, and build-info.txt.
set -euo pipefail

TOP="$(pwd)"
RUN_TESTS="${RUN_TESTS:-1}"

# 10.5p1, from the tree itself: "OpenSSH_10.5" + "p1".
ver="$(sed -n 's/^#define SSH_VERSION[[:space:]]*"OpenSSH_\(.*\)"/\1/p' version.h)"
port="$(sed -n 's/^#define SSH_PORTABLE[[:space:]]*"\(.*\)"/\1/p' version.h)"
OPENSSH_VERSION="${ver}${port}"
[ -n "${ver}" ] && [ -n "${port}" ] || { echo "cannot read the version from version.h"; exit 1; }
PREFIX="/opt/openssh/${OPENSSH_VERSION}"
NAME="openssh-${OPENSSH_VERSION}-bionic-arm64"
echo "building ${NAME}"

# A release tag v<ver>-<n> must name the version it builds.
if [ -n "${RELEASE_TAG:-}" ] && [ "${RELEASE_TAG%-*}" != "v${OPENSSH_VERSION}" ]; then
  echo "tag ${RELEASE_TAG} does not match the source version ${OPENSSH_VERSION}"; exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  build-essential ca-certificates \
  zlib1g-dev libssl-dev libpam0g-dev libaudit-dev >/dev/null

# --sysconfdir=/etc/ssh: share the host keys, moduli and sshd_config with the
# distro package, so the host identity (known_hosts) does not change.
# privsep user/dir: the ones the distro package already created.
# PAM service name is "sshd", so /etc/pam.d/sshd applies unchanged.
./configure \
  --prefix="${PREFIX}" \
  --sysconfdir=/etc/ssh \
  --with-privsep-path=/run/sshd \
  --with-privsep-user=sshd \
  --with-pid-dir=/run \
  --with-pam \
  --with-audit=linux \
  --with-default-path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --with-superuser-path=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

make -j"$(nproc)"

if [ "${RUN_TESTS}" = 1 ]; then
  # The regress suite starts its own sshd instances as the invoking user.
  # The container runs as root, which some tests refuse, so run it as an
  # unprivileged user.
  useradd -m builder 2>/dev/null || true
  chown -R builder: .
  su builder -c 'make tests'
fi

# install-nokeys: never generate host keys. Drop etc/ afterwards: config,
# moduli and keys belong to the host, not to this tarball.
STAGE="$(mktemp -d)"
make install-nokeys DESTDIR="${STAGE}"
rm -rf "${STAGE}/etc"
S="${STAGE}${PREFIX}"
strip "${S}"/sbin/* "${S}"/bin/* "${S}"/libexec/* 2>/dev/null || true

# --- smoke checks ------------------------------------------------------------
mkdir -p "${TOP}/out"
"${S}/sbin/sshd" -V 2>&1 | tee "${TOP}/out/sshd-version.txt"

# Every shared library must resolve from the bionic base.
if ldd "${S}/sbin/sshd" "${S}/libexec/sshd-session" "${S}/libexec/sshd-auth" | grep -q "not found"; then
  ldd "${S}/sbin/sshd" "${S}/libexec/sshd-session" "${S}/libexec/sshd-auth"
  echo "unresolved libraries"; exit 1
fi

# Parse check with a throwaway key, using the config shape nvnano uses, and
# proof that ML-KEM is in the default key exchange list.
tmp="$(mktemp -d)"
"${S}/bin/ssh-keygen" -q -t ed25519 -N '' -f "${tmp}/hk"
cat > "${tmp}/cfg" <<EOF
HostKey ${tmp}/hk
Port 2222
PermitRootLogin prohibit-password
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
EOF
mkdir -p /run/sshd
id sshd >/dev/null 2>&1 || useradd -r -d /run/sshd -s /usr/sbin/nologin sshd
"${S}/sbin/sshd" -t -f "${tmp}/cfg"
# sshd -T prints keywords in mixed case (KexAlgorithms) since 10.x.
"${S}/sbin/sshd" -T -f "${tmp}/cfg" -C user=root,host=localhost,addr=127.0.0.1 \
  | grep -iE '^kexalgorithms ' | tee "${TOP}/out/kex.txt"
grep -q mlkem768x25519-sha256 "${TOP}/out/kex.txt" || { echo "no ML-KEM kex"; exit 1; }
rm -rf "${tmp}"

# Native systemd readiness notification (portable 9.8+, no libsystemd):
# decides Type=notify vs Type=simple in the ansible unit.
if grep -aq NOTIFY_SOCKET "${S}/sbin/sshd"; then sd_notify=yes; else sd_notify=no; fi

# --- package -----------------------------------------------------------------
{
  echo "openssh_version=${OPENSSH_VERSION}"
  echo "prefix=${PREFIX}"
  echo "sd_notify=${sd_notify}"
  echo "built_on=$(. /etc/os-release; echo "${PRETTY_NAME}") $(uname -m)"
  echo "openssl=$(dpkg-query -W -f '${Version}' libssl-dev)"
  echo "commit=${GITHUB_SHA:-local}"
  echo "libraries:"
  ldd "${S}/sbin/sshd" "${S}/libexec/sshd-session" "${S}/libexec/sshd-auth" \
    | awk '/=>/ {print "  " $1}' | sort -u
} > "${S}/BUILD-INFO"
cp "${S}/BUILD-INFO" "${TOP}/out/build-info.txt"

# Owned by root in the archive regardless of who built it.
tar --owner=0 --group=0 --numeric-owner -C "${STAGE}" \
  -czf "${TOP}/out/${NAME}.tar.gz" "${PREFIX#/}"
cd "${TOP}/out"
sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256"
cat "${NAME}.tar.gz.sha256" build-info.txt
