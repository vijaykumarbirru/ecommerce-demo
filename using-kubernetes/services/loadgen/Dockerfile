FROM alpine:3.20
RUN apk add --no-cache curl bash
COPY loadgen.sh /loadgen.sh
RUN chmod +x /loadgen.sh
# bash for $RANDOM; the script itself is POSIX apart from that.
ENTRYPOINT ["bash", "/loadgen.sh"]
