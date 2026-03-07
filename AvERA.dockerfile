# syntax=docker/dockerfile:1

# **********************************************************************
# CPU build:
#   docker build \
#     -t avera:cpu \
#     --build-arg BUILD_IMAGE=debian:bookworm-slim \
#     --build-arg RUNTIME_IMAGE=debian:bookworm-slim \
#     --build-arg USING_CUDA=NO \
#     --build-arg BINARY_NAME=CCLEA \
#     -f AvERA.dockerfile .
#
# CUDA build:
#   docker build \
#     -t avera:cuda \
#     --build-arg BUILD_IMAGE=nvidia/cuda:13.0.0-devel-ubuntu22.04 \
#     --build-arg RUNTIME_IMAGE=nvidia/cuda:13.0.0-runtime-ubuntu22.04 \
#     --build-arg USING_CUDA=YES \
#     --build-arg BINARY_NAME=CCLEA_CUDA \
#     -f AvERA.dockerfile .
#
# Run CPU:
#   docker run --rm -it -v "$HOME/work:/work" -w /work --user "$(id -u):$(id -g)" avera:cpu
#
# Run CUDA:
#   docker run --rm -it --gpus all -v "$HOME/work:/work" -w /work --user "$(id -u):$(id -g)" avera:cuda
# **********************************************************************

ARG BUILD_IMAGE=debian:bookworm-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim

############################
# Build stage
############################
FROM ${BUILD_IMAGE} AS build

ARG DEBIAN_FRONTEND=noninteractive
ARG BOOST_VER=1.90.0
ARG GSL_VER=2.8
ARG CGAL_VER=6.1.1
ARG VORO_VER=0.4.6

ARG USING_CUDA=NO
ARG BINARY_NAME=CCLEA

# NOTE: Here we use HTTPS cloning as SSH keys are usually not available in Docker
ARG DTFE_REPO=https://github.com/MariusCautun/DTFE.git
ARG DTFE_REF=master

ARG AVERA_REPO=https://github.com/eltevo/avera.git
ARG AVERA_REF=master

WORKDIR /downloads

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    bash \
    cmake \
    curl \
    git \
    xz-utils \
    pkg-config \
    autoconf automake libtool m4 \
    libgmp-dev \
    libmpfr-dev \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Fetch sources
RUN set -eux; \
    curl -fsSLO "https://archives.boost.io/release/${BOOST_VER}/source/boost_${BOOST_VER//./_}.tar.gz"; \
    tar -xzf "boost_${BOOST_VER//./_}.tar.gz"; \
    curl -fsSLO "https://mirror.ibcp.fr/pub/gnu/gsl/gsl-${GSL_VER}.tar.gz"; \
    tar -xzf "gsl-${GSL_VER}.tar.gz"; \
    curl -fsSL -o "CGAL-${CGAL_VER}-library.tar.xz" "https://github.com/CGAL/cgal/releases/download/v${CGAL_VER}/CGAL-${CGAL_VER}-library.tar.xz"; \
    tar -xJf "CGAL-${CGAL_VER}-library.tar.xz"; \
    curl -fsSLO "https://math.lbl.gov/voro++/download/dir/voro++-${VORO_VER}.tar.gz"; \
    tar -xzf "voro++-${VORO_VER}.tar.gz"

# BOOST
ENV BOOST_PATH=/opt/boost
RUN set -eux; \
    cd "/downloads/boost_${BOOST_VER//./_}"; \
    ./bootstrap.sh --prefix="${BOOST_PATH}"; \
    ./b2 -j"$(nproc)" install \
      --with-system --with-thread --with-filesystem --with-program_options \
      link=shared runtime-link=shared

# GSL
ENV GSL_PATH=/opt/gsl
RUN set -eux; \
    cd "/downloads/gsl-${GSL_VER}"; \
    ./configure --prefix="${GSL_PATH}"; \
    make -j"$(nproc)"; \
    make install

# CGAL
ENV CGAL_PATH=/opt/cgal
RUN set -eux; \
    cd "/downloads/CGAL-${CGAL_VER}"; \
    cmake -S . -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="${CGAL_PATH}"; \
    cmake --build build -j"$(nproc)"; \
    cmake --install build

# Voro++
ENV VORO_PATH=/opt/voro++
RUN set -eux; \
    cd "/downloads/voro++-${VORO_VER}"; \
    sed -i "s|^PREFIX *=.*|PREFIX=${VORO_PATH}|" config.mk; \
    make -j"$(nproc)"; \
    make install

# DTFE
ENV DTFE_PATH=/opt/dtfe
RUN set -eux; \
    git clone "${DTFE_REPO}" "${DTFE_PATH}"; \
    cd "${DTFE_PATH}"; \
    git checkout "${DTFE_REF}"

RUN set -eux; \
    cd "${DTFE_PATH}"; \
    if [ -f Makefile ]; then \
      sed -i \
        -e "s|^[#[:space:]]*GSL_PATH[[:space:]]*=.*|GSL_PATH=${GSL_PATH}|g" \
        -e "s|^[#[:space:]]*BOOST_PATH[[:space:]]*=.*|BOOST_PATH=${BOOST_PATH}|g" \
        -e "s|^[#[:space:]]*CGAL_PATH[[:space:]]*=.*|CGAL_PATH=${CGAL_PATH}|g" \
        -e "s|^[#[:space:]]*INC_DIR[[:space:]]*=.*|INC_DIR=${DTFE_PATH}/DTFE_include|g" \
        -e "s|^[#[:space:]]*LIB_DIR[[:space:]]*=.*|LIB_DIR=${DTFE_PATH}/DTFE_lib|g" \
        -e "s|^[[:space:]]*HDF5_PATH[[:space:]]*=.*|# HDF5_PATH disabled in container|g" \
        -e "s|^[[:space:]]*MPFR_PATH[[:space:]]*=.*|# MPFR_PATH disabled in container|g" \
        Makefile || true; \
      if grep -qE "^[#[:space:]]*OPTIONS[[:space:]]*\+=.*-DDOUBLE" Makefile; then \
        sed -i "s|^[#[:space:]]*OPTIONS[[:space:]]*\+=.*-DDOUBLE|OPTIONS += -DDOUBLE|" Makefile || true; \
      else \
        echo "OPTIONS += -DDOUBLE" >> Makefile; \
      fi; \
      if ! grep -q "BOOST_TIMER_ENABLE_DEPRECATED" Makefile; then \
        echo "OPTIONS += -DBOOST_TIMER_ENABLE_DEPRECATED" >> Makefile; \
      fi; \
      sed -i "s/-lboost_system//g; s/-lCGAL//g" Makefile || true; \
    fi

ENV CPPFLAGS="-I/opt/boost/include -I/opt/gsl/include -I/opt/cgal/include -I/opt/voro++/include"
ENV LDFLAGS="-L/opt/boost/lib -L/opt/gsl/lib -L/opt/voro++/lib -L/opt/cgal/lib"
ENV LD_LIBRARY_PATH="/opt/boost/lib:/opt/gsl/lib:/opt/voro++/lib:/opt/cgal/lib"

RUN set -eux; \
    cd "${DTFE_PATH}"; \
    mkdir -p DTFE_include DTFE_include/CGAL_triangulation DTFE_lib; \
    make -j"$(nproc)" library

RUN set -eux; \
    cd "${DTFE_PATH}"; \
    [ -d DTFE_include ] && ln -sfn "${DTFE_PATH}/DTFE_include" "${DTFE_PATH}/include" || true; \
    [ -d DTFE_lib ]     && ln -sfn "${DTFE_PATH}/DTFE_lib"     "${DTFE_PATH}/lib"     || true

# AvERA
RUN set -eux; \
    git clone "${AVERA_REPO}" /avera; \
    cd /avera; \
    git checkout "${AVERA_REF}"

RUN set -eux; \
    cd /avera; \
    if [ -f Makefile ]; then \
      sed -i \
        -e "s|^VORO=.*|VORO=${VORO_PATH}/include/voro++|g" \
        -e "s|^DTFE=.*|DTFE=${DTFE_PATH}|g" \
        -e "s|^E_LIB=.*|E_LIB=-L${VORO_PATH}/lib|g" \
        -e "s|^D_LIB=.*|D_LIB=-L${DTFE_PATH}/DTFE_lib|g" \
        Makefile || true; \
      if ! grep -q "Wl,-rpath,${DTFE_PATH}/DTFE_lib" Makefile; then \
        sed -i "s|^LDFLAGS[[:space:]]*+=.*|LDFLAGS += \$(D_LIB) -Wl,-rpath,${DTFE_PATH}/DTFE_lib -Wl,-rpath,${VORO_PATH}/lib|g" Makefile || true; \
      fi; \
    fi

RUN set -eux; \
    ln -sfn "${BOOST_PATH}/include/boost" "${DTFE_PATH}/DTFE_include/boost"

ENV CPPFLAGS="-I/opt/boost/include -I/opt/gsl/include -I/opt/cgal/include -I/opt/voro++/include -I/opt/voro++/include/voro++ -I/opt/dtfe/DTFE_include"
ENV LDFLAGS="-L/opt/boost/lib -L/opt/gsl/lib -L/opt/cgal/lib -L/opt/voro++/lib -L/opt/dtfe/DTFE_lib -Wl,-rpath,/opt/dtfe/DTFE_lib -Wl,-rpath,/opt/voro++/lib"
ENV LD_LIBRARY_PATH="/opt/boost/lib:/opt/gsl/lib:/opt/voro++/lib:/opt/cgal/lib:/opt/dtfe/DTFE_lib"

RUN set -eux; \
    cd /avera; \
    make -j"$(nproc)" USING_CUDA="${USING_CUDA}" CUDA_PATH="/usr/local/cuda"; \
    cp "${BINARY_NAME}" /avera/avera_binary

############################
# Runtime stage
############################
FROM ${RUNTIME_IMAGE} AS runtime

ARG DEBIAN_FRONTEND=noninteractive
ARG UID=1000
ARG GID=1000

ENV BOOST_PATH=/opt/boost \
    GSL_PATH=/opt/gsl \
    CGAL_PATH=/opt/cgal \
    VORO_PATH=/opt/voro++ \
    DTFE_PATH=/opt/dtfe

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libstdc++6 \
    libgcc-s1 \
    libgomp1 \
    libgmp10 \
    libmpfr6 \
    openmpi-bin \
    libopenmpi3 \
    passwd \
    nano \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g "${GID}" avera && \
    useradd -m -u "${UID}" -g "${GID}" -s /bin/bash avera

COPY --from=build ${BOOST_PATH} ${BOOST_PATH}
COPY --from=build ${GSL_PATH} ${GSL_PATH}
COPY --from=build ${CGAL_PATH} ${CGAL_PATH}
COPY --from=build ${VORO_PATH} ${VORO_PATH}
COPY --from=build ${DTFE_PATH} ${DTFE_PATH}

COPY --from=build /avera/avera_binary /usr/local/bin/avera
COPY --from=build /avera/examples/. /avera/

ENV LD_LIBRARY_PATH="/opt/boost/lib:/opt/gsl/lib:/opt/voro++/lib:/opt/cgal/lib:/opt/dtfe/DTFE_lib"

WORKDIR /avera
USER avera
CMD ["/bin/bash"]