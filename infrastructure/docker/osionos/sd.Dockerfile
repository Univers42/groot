# The image engine of osionos-ai (M1): stable-diffusion.cpp's sd-server on Vulkan.
#
# stable-diffusion.cpp publishes no versioned container image: ghcr carries
# only master builds that are overwritten (`master`, `master-vulkan`). So
# the image is built from a GitHub release's own Linux Vulkan binaries,
# fetched by URL and checked against the sha256 the release publishes.
# The release is at least seven days old when pinned: master-964-1d0a58a,
# published 2026-10-13, pinned 2026-10-22.
FROM ubuntu:24.04@sha256:a2d43bffc46670d7108bb3c0468c67c5557c4c92e83e1e34cbff1322ad1b94dc

ADD --checksum=sha256:bade142929edfa7aad56aba46376e55142d14390262b904f4a2deb3a03ceb21d \
	https://github.com/leejet/stable-diffusion.cpp/releases/download/master-964-1d0a58a/sd-master-1d0a58a-bin-Linux-Ubuntu-24.04-x86_64-vulkan.zip \
	/tmp/sd.zip

RUN apt-get update \
	&& apt-get install -y --no-install-recommends libvulkan1 mesa-vulkan-drivers libgomp1 unzip \
	&& unzip -q /tmp/sd.zip -d /opt/sd \
	&& rm /tmp/sd.zip \
	&& apt-get purge -y unzip \
	&& apt-get autoremove -y \
	&& rm -rf /var/lib/apt/lists/*

ENV LD_LIBRARY_PATH=/opt/sd
# The GPU is reached through /dev/dri, whose groups compose adds (group_add).
USER ubuntu
ENTRYPOINT ["/opt/sd/sd-server"]
