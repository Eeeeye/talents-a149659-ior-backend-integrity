FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90

ARG DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_SNAPSHOT=20260815T000000Z

RUN sed -i \
      -e "s#http://archive.ubuntu.com/ubuntu/#http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#" \
      -e "s#http://security.ubuntu.com/ubuntu/#http://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}/#" \
      /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install -y --no-install-recommends \
       ca-certificates=20260601~24.04.1 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       autoconf=2.71-3 \
       automake=1:1.16.5-1.3ubuntu1 \
       build-essential=12.10ubuntu1 \
       libaio-dev=0.3.113-6build1.1 \
       libopenmpi-dev=4.1.6-7ubuntu2 \
       libtool=2.4.7-7build1 \
       openmpi-bin=4.1.6-7ubuntu2 \
       patch=2.7.6-7build3 \
       perl=5.38.2-3.2ubuntu0.3 \
       pkg-config=1.8.1-2build1 \
    && apt-get clean \
    && find /var/lib/apt/lists -mindepth 1 -delete

ENV OMPI_ALLOW_RUN_AS_ROOT=1 \
    OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1 \
    OMPI_MCA_rmaps_base_oversubscribe=1 \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

COPY task/ /work/ior/

WORKDIR /work/ior

RUN chmod +x scripts/build.sh scripts/reproduce.sh \
    && scripts/build.sh
