FROM alpine:3.20
RUN apk add --no-cache busybox-extras
COPY www /www
USER 65532:65532
EXPOSE 8080
CMD ["busybox-extras", "httpd", "-f", "-v", "-p", "8080", "-h", "/www"]
