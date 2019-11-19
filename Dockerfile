FROM frolvlad/alpine-gcc as base

RUN apk add --no-cache ghc curl git

RUN curl -L https://github.com/nh2/stack/releases/download/v1.6.5/stack-prerelease-1.9.0.1-x86_64-unofficial-fully-static-musl > /usr/bin/stack

RUN chmod +x /usr/bin/stack

RUN git clone https://github.com/chrisdone/duet.git --depth 1 && cd duet && git checkout 186d4dbf85f23e28862fce7e8160adddfdb8d36f
RUN cd duet && stack update
RUN apk add --no-cache zlib-dev
RUN cd duet && stack build --system-ghc --dependencies-only

RUN cd duet && git pull && git checkout 67c561e3be3d67455a6dd1f8ba07fcd309365d3d
RUN cd duet && stack install --system-ghc --fast

FROM alpine:3.9
RUN apk add --no-cache gmp libffi

COPY --from=base /root/.local/bin/duet /usr/bin/duet

ENTRYPOINT ["duet"]
