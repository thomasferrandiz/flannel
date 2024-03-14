FROM --platform=$BUILDPLATFORM tonistiigi/xx AS xx

FROM --platform=$BUILDPLATFORM golang:alpine AS build
# copy xx scripts to your build stage
COPY --from=xx / /
# ARG BUILDPLATFORM
RUN apk --no-cache add bash make gcc musl-dev git linux-headers git
COPY Makefile go.mod go.sum *.go /build/
COPY pkg /build/pkg
WORKDIR /build
RUN mkdir dist
RUN xx-info env
RUN go mod download
# clone iptables-wrapper before forking for each TARGETPLATFORM
# note: iptables-wrapper does not have any dependencies to download
RUN git clone https://github.com/kubernetes-sigs/iptables-wrappers.git /iptables-wrapper
ARG TARGETPLATFORM
RUN xx-go --wrap &&\
    export ARCH=$(xx-info arch) &&\
     make dist/flanneld
RUN xx-verify --static /build/dist/flanneld
# build iptables-wrapper
WORKDIR /iptables-wrapper
RUN git checkout 5792812d9e5a5bb7f22d79d557bbfeece253343d
RUN xx-go --wrap &&\
    export ARCH=$(xx-info arch) &&\
    make build
RUN xx-verify --static /iptables-wrapper/bin/iptables-wrapper

FROM alpine:20231219
ARG TARGETPLATFORM
RUN apk update && apk upgrade
RUN apk add --no-cache iproute2 ca-certificates iptables strongswan iptables-legacy && update-ca-certificates
RUN apk add wireguard-tools --no-cache --repository http://dl-cdn.alpinelinux.org/alpine/edge/community
COPY --from=build /build/dist/flanneld /opt/bin/flanneld
COPY dist/mk-docker-opts.sh /opt/bin/
COPY --from=build /iptables-wrapper/iptables-wrapper-installer.sh /
COPY --from=build /iptables-wrapper/bin/iptables-wrapper /
# check manually that iptables-legacy and iptables-nft are present since
# iptables-wrapper-installer.sh sanity check doesn't work for multi-arch build
RUN which iptables-legacy && which iptables-nft
RUN /iptables-wrapper-installer.sh --no-sanity-check


ENTRYPOINT ["/opt/bin/flanneld"]

