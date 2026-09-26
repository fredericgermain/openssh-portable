# bionic-arm64 branch

An upgraded OpenSSH for the NVIDIA Jetson Nano (Ubuntu 18.04 / L4T r32.7.6,
arm64). Ubuntu 18.04 ships OpenSSH 7.6: Canonical ESM keeps patching it, but
it will never gain post-quantum key exchange (`mlkem768x25519-sha256`, 9.9+).

This branch is an upstream release tag plus CI, and nothing else:

- `ci/build-bionic-arm64.sh`: builds the tree inside `arm64v8/ubuntu:18.04`,
  so it links against bionic's glibc 2.27, libssl1.1 and libpam. It then runs
  `make tests` and smoke-checks the result: ML-KEM is in the default key
  exchange list, and every library resolves. It packages
  `/opt/openssh/<version>/` only, with no config and no host keys.
- `.github/workflows/build-bionic-arm64.yml`: runs that on GitHub's native
  arm64 runner. A `v<version>-<n>` tag publishes a release with the tarball,
  its sha256 and `build-info.txt`.
- Upstream's own workflows are removed on this branch. They target upstream's
  CI matrix and self-hosted runners.

## Moving to a new upstream release

    git fetch upstream --tags
    git rebase --onto V_<X>_<Y>_P<Z> V_10_5_P1 bionic-arm64
    git push -f origin bionic-arm64          # CI builds and tests it
    git tag v<X>.<Y>p<Z>-1 && git push origin v<X>.<Y>p<Z>-1

The tree at a release tag is identical to upstream's signed tarball. To
check this, compare `git archive V_<...>` against the tarball after verifying
its `.asc` with the release key
(`7168 B983 815A 5EEF 59A4 ADFD 2A3F 414E 7360 60BA`).

## Installing

The build expects the distro `openssh-server` package to stay installed, for
its privsep user, `/run/sshd`, the PAM config and the host keys. The new sshd
shares `/etc/ssh/sshd_config` with it, and that file must stay valid for 7.6.
The unit, the guarded cutover and the rollback live in the manergi ansible
repo, `roles/infra/openssh_upstream`.
