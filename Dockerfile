# openEMS images with the HIP GPU engine, from plain Ubuntu (see README.md). The engine
# compiles for both vendors from one source, so there is an image per vendor: an AMD user
# has no reason to carry CUDA, nor an NVIDIA user ROCm. Targets:
#   dev:         build tools, the CUDA compiler and HIP over it, and the dependencies of
#                openEMS; sync the sources and run build-openems
#   dev-amd:     the same with ROCm, for AMD GPUs
#   runtime:     openEMS and its Python bindings for NVIDIA, built in dev for all supported
#                architectures, with only the libraries they load; no build tools
#   runtime-amd: the same for AMD, with the ROCm runtime
# Build context: this directory (the scripts). The openEMS sources of the runtime target:
# - OPENEMS_SOURCE=github (default): openEMS from the GPU branch on GitHub, CSXCAD and fparser
#   from upstream at the commits it is tested with,
# - OPENEMS_SOURCE=local: a local openEMS-Project directory (fparser, CSXCAD, openEMS and
#   .git/modules) as the named context openems-src,
#   e.g. --build-context openems-src=../openEMS-Project
# build.sh picks local if it finds an openEMS-Project tree next to this directory.
#
# No NVIDIA driver in the images: the NVIDIA Container Toolkit of the host mounts its driver
# libraries and nvidia-smi (NVIDIA_DRIVER_CAPABILITIES), matching the host's kernel module.

ARG UBUNTU=ubuntu:24.04
ARG CUDA_VERSION=12-8
ARG BTOP_VERSION=v1.4.7
# machine code for Pascal to Blackwell, and PTX of the newest for later GPUs
ARG CUDA_ARCHITECTURES="60-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;100-real;120"
# The AMD GPUs the engine is built for: CDNA 1 to 3 (MI100, MI200, MI300, MI350), RDNA 2
# (RX 6000), RDNA 3 (RX 7000, and the Phoenix and Strix Halo APUs) and RDNA 4 (RX 9000).
# A GPU outside the list falls back to the CPU, so the list is what makes the image useful
# on a given machine; every entry is a full compile of the kernels.
ARG AMD_ARCHITECTURES="gfx908;gfx90a;gfx942;gfx950;gfx1030;gfx1100;gfx1101;gfx1102;gfx1103;gfx1151;gfx1200;gfx1201"
ARG ROCM_REPO=https://repo.radeon.com/rocm/apt/latest
ARG OPENEMS_SOURCE=github

FROM ${UBUNTU} AS base
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility

# btop from source, with GPU monitoring (it loads the NVML of the host driver). It needs C++23:
# GCC 14 (Ubuntu 24.04's libstdc++ is from GCC 14, so the runtime image has what it links).
FROM base AS btop
ARG BTOP_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends build-essential g++-14 git ca-certificates \
    && git clone --depth 1 --branch ${BTOP_VERSION} https://github.com/aristocratos/btop /tmp/btop \
    && make -C /tmp/btop -j$(nproc) GPU_SUPPORT=true CXX=g++-14 \
    && make -C /tmp/btop install PREFIX=/usr/local DESTDIR=/out \
    && strip /out/usr/local/bin/btop

# everything both dev images need, without a GPU toolchain
FROM base AS dev-common
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
        build-essential cmake git rsync time bsdextrautils \
        openssh-server tmux wget curl less locales sudo software-properties-common \
        libhdf5-dev libvtk9-dev libcgal-dev libtinyxml-dev libgmp-dev libmpfr-dev \
        libboost-program-options-dev libboost-thread-dev libboost-date-time-dev \
        libboost-serialization-dev libboost-chrono-dev libboost-system-dev \
        python3-dev python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Python environment for the openEMS/CSXCAD bindings and the tests
RUN python3 -m venv /opt/openEMS/venv \
    && /opt/openEMS/venv/bin/pip install --no-cache-dir --upgrade \
        pip setuptools setuptools_scm cython numpy h5py matplotlib scipy

# the synced submodules are owned by another user
RUN git config --system --add safe.directory '*'

COPY --from=btop /out/usr/local/ /usr/local/
COPY build-openems run-test run-bench collect-runtime-libs /opt/openEMS/tools/
COPY sitecustomize.py /opt/openEMS/tools/inject/
# Like the runtime images, these are meant to run as the invoking user
# (--user $(id -u):$(id -g)) so that what they write into the mounted /workspace belongs to
# them. build-openems installs into /opt/openEMS and pip-installs the bindings into its venv,
# so that tree has to be writable whatever the uid is, and /root is not.
RUN chmod -R a+rwX /opt/openEMS
ENV HOME=/tmp \
    MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /workspace

# NVIDIA: the CUDA compiler and runtime from NVIDIA's repository, and HIP over them. On this
# platform HIP is headers over the CUDA runtime, nvcc compiles the kernels and the binaries
# link the CUDA runtime, so hip-dev is enough: hipcc-nvidia would bring a hipcc of its own
# and collide with the one of hip-dev over the same file. build-openems names the compiler
# rather than have CMake look for it, which is what would have wanted hipcc.
# The pin is the one of the AMD images: Ubuntu carries ROCm 5.7 of its own, and the headers
# of the two releases do not mix (__AMDGCN_WAVEFRONT_SIZE is undeclared in the older ones).
FROM dev-common AS dev
ARG CUDA_VERSION
ARG ROCM_REPO
RUN curl -fsSL -o /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb \
    && dpkg -i /tmp/cuda-keyring.deb && rm /tmp/cuda-keyring.deb \
    && curl -fsSL ${ROCM_REPO%/apt/latest}/rocm.gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] ${ROCM_REPO} noble main" > /etc/apt/sources.list.d/rocm.list \
    && printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/rocm \
    && apt-get update && apt-get install -y --no-install-recommends \
        cuda-nvcc-${CUDA_VERSION} cuda-cudart-dev-${CUDA_VERSION} cuda-profiler-api-${CUDA_VERSION} \
        cuda-cuobjdump-${CUDA_VERSION} \
        hip-dev rocm-core \
    && rm -rf /var/lib/apt/lists/*
ENV HIP_PLATFORM=nvidia \
    PATH=/opt/openEMS/tools:/opt/openEMS/bin:/opt/rocm/bin:/usr/local/cuda/bin:${PATH}

# AMD: the ROCm compiler. Here HIP is a runtime library the binaries link.
FROM dev-common AS dev-amd
ARG ROCM_REPO
# Ubuntu carries ROCm 5.7 packages of its own, and a mix of the two puts the headers of one
# beside the compiler of the other (__AMDGCN_WAVEFRONT_SIZE undeclared). The pin keeps every
# ROCm package on the AMD repository.
RUN curl -fsSL ${ROCM_REPO%/apt/latest}/rocm.gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] ${ROCM_REPO} noble main" > /etc/apt/sources.list.d/rocm.list \
    && printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/rocm \
    && apt-get update && apt-get install -y --no-install-recommends \
        hipcc hip-dev rocm-device-libs rocm-llvm comgr hsa-rocr-dev rocminfo rocm-smi-lib \
    && rm -rf /var/lib/apt/lists/*
# ROCM_PATH: CMake looks for the HIP compiler under it (/opt/rocm/llvm/bin/clang++) and
# finds nothing without it, which would leave the GPU backend out of the build
ENV HIP_PLATFORM=amd \
    ROCM_PATH=/opt/rocm \
    PATH=/opt/openEMS/tools:/opt/openEMS/bin:/opt/rocm/bin:${PATH}

# what the runtime image gets from apt: its libraries are not copied (see collect-runtime-libs).
# bsdextrautils: column. The rest is what Vast.ai installs into a container at every start:
# having them saves that wait (https://docs.vast.ai).
FROM base AS runtime-base
RUN apt-get update && apt-get install -y --no-install-recommends python3 bsdextrautils \
        openssh-server tmux git wget curl less locales sudo software-properties-common rsync \
    && rm -rf /var/lib/apt/lists/*

FROM runtime-base AS runtime-packages
RUN dpkg-query -W -f='${Package}\n' > /runtime.packages

# the AMD runtime image carries the ROCm runtime, so its libraries must not be collected
FROM runtime-base AS runtime-amd-base
ARG ROCM_REPO
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
    && curl -fsSL ${ROCM_REPO%/apt/latest}/rocm.gpg.key | gpg --dearmor > /etc/apt/trusted.gpg.d/rocm.gpg \
    && echo "deb [arch=amd64] ${ROCM_REPO} noble main" > /etc/apt/sources.list.d/rocm.list \
    && printf 'Package: *\nPin: origin repo.radeon.com\nPin-Priority: 1001\n' > /etc/apt/preferences.d/rocm \
    && apt-get update && apt-get install -y --no-install-recommends hip-runtime-amd rocm-smi-lib \
    && rm -rf /var/lib/apt/lists/*

FROM runtime-amd-base AS runtime-amd-packages
RUN dpkg-query -W -f='${Package}\n' > /runtime.packages

# the openEMS sources in /src, see OPENEMS_SOURCE
FROM base AS src-local
COPY --from=openems-src fparser /src/fparser
COPY --from=openems-src CSXCAD /src/CSXCAD
COPY --from=openems-src openEMS /src/openEMS
COPY --from=openems-src .git/modules /src/.git/modules

FROM dev-common AS src-github
ARG OPENEMS_REPO=SeanMollet/openEMS
ARG OPENEMS_BRANCH=GPU_experiments
ARG CSXCAD_COMMIT=bd2c133392d93251b640da1f8e2367163f00b7f5
ARG FPARSER_COMMIT=4b9c845b449b520c4b8c5f23c74cd04820084f81
# the current commit of the branch: a new one invalidates the clone below
ADD https://api.github.com/repos/${OPENEMS_REPO}/git/refs/heads/${OPENEMS_BRANCH} /tmp/openems-ref.json
# full clones: the version numbers come from git describe
RUN git clone --branch ${OPENEMS_BRANCH} https://github.com/${OPENEMS_REPO}.git /src/openEMS \
    && git clone https://github.com/thliebig/CSXCAD.git /src/CSXCAD && git -C /src/CSXCAD checkout -q ${CSXCAD_COMMIT} \
    && git clone https://github.com/thliebig/fparser.git /src/fparser && git -C /src/fparser checkout -q ${FPARSER_COMMIT}

FROM src-${OPENEMS_SOURCE} AS src

# openEMS for the runtime image: the libraries and programs, a venv with the bindings and
# their runtime packages only, and the shared libraries they load that apt does not provide there
FROM dev AS openems-build
ARG CUDA_ARCHITECTURES
COPY --from=src /src /src
RUN CUDA_ARCH="${CUDA_ARCHITECTURES}" BUILD_PYTHON=0 build-openems /src
RUN set -e; P=/opt/openEMS; \
    for py in CSXCAD openEMS; do \
        cd /src/$py/python && rm -rf build; \
        CSXCAD_INSTALL_PATH=$P OPENEMS_INSTALL_PATH=$P $P/venv/bin/pip wheel --no-build-isolation --no-deps -w /wheels .; \
        $P/venv/bin/pip install --no-deps /wheels/$(echo $py | tr A-Z a-z)-*.whl; \
    done; \
    rm -rf $P/venv; \
    python3 -m venv $P/venv; \
    $P/venv/bin/pip install --no-cache-dir numpy h5py matplotlib /wheels/*.whl; \
    # only our files: stripping the libraries bundled in the wheels can break them (patchelf)
    for f in $(find $P/bin $P/lib $P/venv/lib/python3*/site-packages/CSXCAD $P/venv/lib/python3*/site-packages/openEMS \
               -type f \( -name '*.so*' -o -perm -u+x \)); do \
        strip --strip-unneeded $f 2>/dev/null || true; \
    done
COPY --from=runtime-packages /runtime.packages /tmp/
RUN collect-runtime-libs /tmp/runtime.packages /opt/openEMS/deps /opt/openEMS/bin /opt/openEMS/lib /opt/openEMS/venv

# the same for AMD, from the ROCm dev image
FROM dev-amd AS openems-build-amd
ARG AMD_ARCHITECTURES
COPY --from=src /src /src
RUN GPU_ARCH="${AMD_ARCHITECTURES}" BUILD_PYTHON=0 build-openems /src
RUN set -e; P=/opt/openEMS; \
    for py in CSXCAD openEMS; do \
        cd /src/$py/python && rm -rf build; \
        CSXCAD_INSTALL_PATH=$P OPENEMS_INSTALL_PATH=$P $P/venv/bin/pip wheel --no-build-isolation --no-deps -w /wheels .; \
        $P/venv/bin/pip install --no-deps /wheels/$(echo $py | tr A-Z a-z)-*.whl; \
    done; \
    rm -rf $P/venv; \
    python3 -m venv $P/venv; \
    $P/venv/bin/pip install --no-cache-dir numpy h5py matplotlib /wheels/*.whl; \
    for f in $(find $P/bin $P/lib $P/venv/lib/python3*/site-packages/CSXCAD $P/venv/lib/python3*/site-packages/openEMS \
               -type f \( -name '*.so*' -o -perm -u+x \)); do \
        strip --strip-unneeded $f 2>/dev/null || true; \
    done
COPY --from=runtime-amd-packages /runtime.packages /tmp/
RUN collect-runtime-libs /tmp/runtime.packages /opt/openEMS/deps /opt/openEMS/bin /opt/openEMS/lib /opt/openEMS/venv

FROM runtime-base AS runtime
COPY --from=btop /out/usr/local/ /usr/local/
COPY --from=openems-build /opt/openEMS/bin /opt/openEMS/bin
COPY --from=openems-build /opt/openEMS/lib /opt/openEMS/lib
COPY --from=openems-build /opt/openEMS/deps /opt/openEMS/deps
COPY --from=openems-build /opt/openEMS/venv /opt/openEMS/venv
# every library resolves (the CUDA driver is loaded at run time), and the bindings import
RUN printf '/opt/openEMS/lib\n/opt/openEMS/deps\n' > /etc/ld.so.conf.d/openems.conf && ldconfig \
    && ! find /opt/openEMS -type f \( -name '*.so*' -o -perm -u+x \) -exec ldd {} + 2>/dev/null | grep "not found" \
    && cd /tmp && /opt/openEMS/venv/bin/python -c "import CSXCAD, openEMS, h5py, matplotlib"
# HOME and MPLCONFIGDIR under /tmp, which is writable whatever the uid: the image is meant to
# run as the invoking user (--user $(id -u):$(id -g)), so that the results it writes into the
# mounted /workspace belong to them and not to root, and /root is then not writable.
ENV PATH=/opt/openEMS/venv/bin:/opt/openEMS/bin:${PATH} \
    HOME=/tmp \
    MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /workspace

FROM runtime-amd-base AS runtime-amd
COPY --from=btop /out/usr/local/ /usr/local/
COPY --from=openems-build-amd /opt/openEMS/bin /opt/openEMS/bin
COPY --from=openems-build-amd /opt/openEMS/lib /opt/openEMS/lib
COPY --from=openems-build-amd /opt/openEMS/deps /opt/openEMS/deps
COPY --from=openems-build-amd /opt/openEMS/venv /opt/openEMS/venv
# every library resolves (the kernel driver is on the host, /dev/kfd and /dev/dri are passed
# to the container), and the bindings import
RUN printf '/opt/openEMS/lib\n/opt/openEMS/deps\n' > /etc/ld.so.conf.d/openems.conf && ldconfig \
    && ! find /opt/openEMS -type f \( -name '*.so*' -o -perm -u+x \) -exec ldd {} + 2>/dev/null | grep "not found" \
    && cd /tmp && /opt/openEMS/venv/bin/python -c "import CSXCAD, openEMS, h5py, matplotlib"
# HOME and MPLCONFIGDIR under /tmp, which is writable whatever the uid: the image is meant to
# run as the invoking user (--user $(id -u):$(id -g)), so that the results it writes into the
# mounted /workspace belong to them and not to root, and /root is then not writable.
ENV PATH=/opt/openEMS/venv/bin:/opt/openEMS/bin:${PATH} \
    HOME=/tmp \
    MPLCONFIGDIR=/tmp/matplotlib
WORKDIR /workspace
