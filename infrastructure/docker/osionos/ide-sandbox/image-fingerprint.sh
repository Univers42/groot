# image-fingerprint.sh: the docker template deploy-plane.sh and check-plane.sh compare an
# image by, on the build machine and on the VM. Sourced; defines FINGERPRINT only.
#
# An image's .Id is not portable: the classic store reports the config digest, the
# containerd store (the VM, Docker 29.9) the manifest digest, so the same image has two
# ids. Its config plus its layer list is the same on both and is what is compared.
# The config is read field by field, not as {{json .Config}}: Docker 28.1 prints the
# zero-value fields (AttachStdin, Tty, Labels null, …) and 29.9 omits them, so the whole
# object never matched across the two (2026-10-17: identical layers, deploy refused).
# Caveat: build history and timestamps are left out, so two builds with identical config
# and layers count as one image; a config field not listed here is not compared.
# shellcheck disable=SC2034 # read by deploy-plane.sh and check-plane.sh, which source this file
FINGERPRINT='{{json .Config.User}} {{json .Config.Env}} {{json .Config.Cmd}} {{json .Config.Entrypoint}} {{json .Config.WorkingDir}} {{json .Config.ExposedPorts}} {{json .Config.Volumes}} {{json .Config.Labels}} {{json .Config.Healthcheck}} {{json .Config.StopSignal}} {{json .Config.Shell}} {{json .Config.OnBuild}} {{json .RootFS.Layers}}'
